#include <string.h>
#include <platform.h>
#include "rgmii_buffering.h"
#include "rgmii_common.h"
#define DEBUG_UNIT RGMII_CLIENT_HANDLER
#include "debug_print.h"
#include "print.h"
#include "xassert.h"
#include "macaddr_filter_hash.h"

extern inline void enable_rgmii(unsigned delay, unsigned divide);

static inline unsigned int get_tile_id_from_chanend(streaming chanend c) {
  unsigned int tile_id;
  asm("shr %0, %1, 16":"=r"(tile_id):"r"(c));
  return tile_id;
}

#ifndef RGMII_RX_BUFFERS_THRESHOLD
// When using the high priority queue and there are less than this number of buffers
// free then low priority packets start to be dropped
#define RGMII_RX_BUFFERS_THRESHOLD (RGMII_MAC_BUFFER_COUNT_RX / 2)
#endif

#define LOCK(buffers) hwlock_acquire(ethernet_memory_lock)
#define UNLOCK(buffers) hwlock_release(ethernet_memory_lock)

void buffers_free_initialize(buffers_free_t &free, unsigned char *buffer,
                             unsigned *pointers, unsigned buffer_count)
{
  free.top_index = buffer_count;
  unsafe {
    free.stack = (unsigned * unsafe)pointers;
    free.stack[0] = (uintptr_t)buffer;
    for (unsigned i = 1; i < buffer_count; i++)
      free.stack[i] = free.stack[i - 1] + sizeof(mii_packet_t);
  }
}

void buffers_used_initialize(buffers_used_t &used, unsigned *pointers)
{
  used.head_index = 0;
  used.tail_index = 0;
  unsafe {
    used.pointers = pointers;
  }
}

static inline unsigned buffers_free_available(buffers_free_t &free)
{
  return free.top_index;
}

#pragma unsafe arrays
static unsafe inline mii_packet_t * unsafe buffers_free_take(buffers_free_t &free)
{
  LOCK(free);

  mii_packet_t * unsafe buf = NULL;

  // Ensure that the compiler does not keep this value in a register
  volatile unsigned * unsafe p_top_index = (volatile unsigned * unsafe)(&free.top_index);
  unsigned top_index = *p_top_index;

  if (top_index != 0) {
    top_index--;
    buf = (mii_packet_t *)free.stack[top_index];
    *p_top_index = top_index;
  }

  UNLOCK(free);
  return buf;
}

#pragma unsafe arrays
static unsafe inline void buffers_free_add(buffers_free_t &free, mii_packet_t * unsafe buf)
{
  LOCK(free);

  // Ensure that the compiler does not keep this value in a register
  volatile unsigned * unsafe p_top_index = (volatile unsigned * unsafe)(&free.top_index);
  unsigned top_index = *p_top_index;

  unsafe {
    free.stack[top_index] = (uintptr_t)buf;
  }
  top_index++;
  *p_top_index = top_index;

  UNLOCK(free);
}

#pragma unsafe arrays
static unsafe inline unsafe uintptr_t * unsafe buffers_used_add(buffers_used_t &used,
                                                                mii_packet_t * unsafe buf,
                                                                unsigned buffer_count)
{
  LOCK(free);

  // Ensure that the compiler does not keep this value in a register
  volatile unsigned * unsafe p_head_index = (volatile unsigned * unsafe)(&used.head_index);
  unsigned head_index = *p_head_index;

  unsigned index = head_index % buffer_count;
  used.pointers[index] = (uintptr_t)buf;
  head_index++;
  *p_head_index = head_index;

  UNLOCK(free);

  return &used.pointers[index];
}

#pragma unsafe arrays
static unsafe inline mii_packet_t * unsafe buffers_used_take(buffers_used_t &used, unsigned buffer_count)
{
  LOCK(free);

  // Ensure that the compiler does not keep this value in a register
  volatile unsigned * unsafe p_tail_index = (volatile unsigned * unsafe)(&used.tail_index);
  unsigned tail_index = *p_tail_index;

  unsigned index = tail_index % buffer_count;
  tail_index++;
  *p_tail_index = tail_index;

  unsafe {
    mii_packet_t * unsafe buf = (mii_packet_t *)used.pointers[index];
    UNLOCK(free);
    return buf;
  }
}

#pragma unsafe arrays
static unsafe inline int buffers_used_empty(buffers_used_t &used)
{
  // Ensure that the compiler does not keep this value in a register
  volatile unsigned * unsafe p_head_index = (volatile unsigned * unsafe)(&used.head_index);
  unsigned head_index = *p_head_index;
  volatile unsigned * unsafe p_tail_index = (volatile unsigned * unsafe)(&used.tail_index);
  unsigned tail_index = *p_tail_index;

  return tail_index == head_index;
}

void empty_channel(streaming chanend c)
{
  // Remove all data from the channels. Assumes data will all be words.
  timer t;
  unsigned time;
  t :> time;

  int done = 0;
  unsigned tmp;
  while (!done) {
    select {
      case c :> tmp:
        // Re-read the current time so that the timeout is from last data received
        t :> time;
        break;
      case t when timerafter(time + 100) :> void:
        done = 1;
        break;
    }
  }
}

#pragma unsafe arrays
unsafe void rgmii_buffer_manager(streaming chanend c_rx,
                                 streaming chanend c_speed_change,
                                 buffers_used_t &used_buffers_rx_lp,
                                 buffers_used_t &used_buffers_rx_hp,
                                 buffers_free_t &free_buffers,
                                 unsigned filter_num)
{
  set_core_fast_mode_on();

  // Start by issuing buffers to both of the miis
  c_rx <: (uintptr_t)buffers_free_take(free_buffers);

  // Give a second buffer to ensure no delay between packets
  c_rx <: (uintptr_t)buffers_free_take(free_buffers);

  int done = 0;
  while (!done) {
    mii_macaddr_hash_table_t * unsafe table = mii_macaddr_get_hash_table(filter_num);

    select {
      case c_rx :> uintptr_t buffer :
        // Get the next available buffer
        uintptr_t next_buffer = (uintptr_t)buffers_free_take(free_buffers);

        if (next_buffer) {
          // There was a buffer free
          mii_packet_t *buf = (mii_packet_t *)buffer;

          // Ensure it is marked as invalid
          c_rx <: next_buffer;

          // Use the destination MAC addresses as the key for the hash
          unsigned key0 = buf->data[0];
          unsigned key1 = buf->data[1] & 0xffff;
          unsigned filter_result = mii_macaddr_hash_lookup(table, key0, key1, &buf->filter_data);
          if (filter_result) {
            buf->filter_result = filter_result;
            buf->filter_data = 0;

            if (ethernet_filter_result_is_hp(filter_result))
              buffers_used_add(used_buffers_rx_hp, (mii_packet_t *)buffer, RGMII_MAC_BUFFER_COUNT_RX);
            else
              buffers_used_add(used_buffers_rx_lp, (mii_packet_t *)buffer, RGMII_MAC_BUFFER_COUNT_RX);
          }
          else {
            // Drop the packet
            buffers_free_add(free_buffers, (mii_packet_t *)buffer);
          }
        }
        else {
          // There are no buffers available. Drop this packet and reuse buffer.
          c_rx <: buffer;
        }
        break;

      case c_speed_change :> unsigned tmp:
        done = 1;
        break;

      default:
        // Ensure that the hash table pointer is being updated even when
        // there are no packets on the wire
        break;
    }
  }

  // Clean up before changing speed
  empty_channel(c_rx);
}

unsafe static void handle_incoming_packet(rx_client_state_t client_states[n],
                                          server ethernet_rx_if i_rx[n],
                                          unsigned n,
                                          buffers_used_t &used_buffers,
                                          buffers_free_t &free_buffers)
{
  if (buffers_used_empty(used_buffers))
    return;

  mii_packet_t * unsafe buf = (mii_packet_t *)buffers_used_take(used_buffers, RGMII_MAC_BUFFER_COUNT_RX);

  int tcount = 0;
  if (buf->filter_result) {
    for (int i = 0; i < n; i++) {
      rx_client_state_t &client_state = client_states[i];

      int client_wants_packet = ((buf->filter_result >> i) & 1);
      if (client_state.num_etype_filters != 0) {
        char * unsafe data = (char * unsafe) buf->data;
        int passed_etype_filter = 0;
        uint16_t etype = ((uint16_t) data[12] << 8) + data[13];
        int qhdr = (etype == 0x8100);
        if (qhdr) {
          // has a 802.1q tag - read etype from next word
          etype = ((uint16_t) data[16] << 8) + data[17];
        }
        for (int j = 0; j < client_state.num_etype_filters; j++) {
          if (client_state.etype_filters[j] == etype) {
            passed_etype_filter = 1;
            break;
          }
        }
        client_wants_packet &= passed_etype_filter;
      }

      if (client_wants_packet) {
        int wrptr = client_state.wr_index;
        int new_wrptr = wrptr + 1;
        if (new_wrptr >= ETHERNET_RX_CLIENT_QUEUE_SIZE) {
          new_wrptr = 0;
        }
        if (new_wrptr != client_state.rd_index) {
          client_state.fifo[wrptr] = (void *)buf;
          tcount++;
          i_rx[i].packet_ready();
          client_state.wr_index = new_wrptr;

        } else {
          client_state.dropped_pkt_cnt += 1;
        }
      }
    }
  }

  if (tcount == 0) {
    // Packet filtered or not wanted or no-one wanted the buffer so release it
    buffers_free_add(free_buffers, buf);
  } else {
    buf->tcount = tcount - 1;
  }
}

unsafe static void drop_lp_packets(rx_client_state_t client_states[n], unsigned n,
                                   buffers_used_t &used_buffers_rx_lp,
                                   buffers_free_t &free_buffers)
{
  for (int i = 0; i < n; i++) {
    rx_client_state_t &client_state = client_states[i];

    unsigned rd_index = client_state.rd_index;
    if (rd_index != client_state.wr_index) {
      mii_packet_t * unsafe buf = (mii_packet_t * unsafe)client_state.fifo[rd_index];

      if (mii_get_and_dec_transmit_count(buf) == 0) {
        buffers_free_add(free_buffers, buf);
      }
      client_state.rd_index = increment_and_wrap_power_of_2(rd_index,
                                                            ETHERNET_RX_CLIENT_QUEUE_SIZE);
      client_state.dropped_pkt_cnt += 1;
    }
  }
}

unsafe void rgmii_ethernet_rx_server_aux(rx_client_state_t client_state_lp[n_rx_lp],
                                         server ethernet_rx_if i_rx_lp[n_rx_lp], unsigned n_rx_lp,
                                         streaming chanend ? c_rx_hp,
                                         streaming chanend c_status_update,
                                         streaming chanend c_speed_change,
                                         out port p_txclk_out,
                                         in buffered port:4 p_rxd_interframe,
                                         buffers_used_t &used_buffers_rx_lp,
                                         buffers_used_t &used_buffers_rx_hp,
                                         buffers_free_t &free_buffers,
                                         rgmii_inband_status_t current_mode)
{
  set_core_fast_mode_on();

  set_port_inv(p_txclk_out);

  // Signal to the testbench that the device is ready
  enable_rgmii(RGMII_DELAY, RGMII_DIVIDE_1G);

  // Ensure that interrupts will be generated on this core
  install_speed_change_handler(p_rxd_interframe, current_mode);

  ethernet_link_state_t link_status = ETHERNET_LINK_DOWN;

  int done = 0;
  while (1) {
    select {
      case i_rx_lp[int i].get_index() -> size_t result:
        result = i;
        break;

      case i_rx_lp[int i].get_packet(ethernet_packet_info_t &desc, char data[n], unsigned n):
        rx_client_state_t &client_state = client_state_lp[i];

        if (client_state.status_update_state == STATUS_UPDATE_PENDING) {
          data[0] = 1;
          data[1] = link_status;
          desc.type = ETH_IF_STATUS;
          client_state.status_update_state = STATUS_UPDATE_WAITING;
        }
        else if (client_state.rd_index != client_state.wr_index) {
          // send received packet
          int rd_index = client_state.rd_index;
          mii_packet_t * unsafe buf = (mii_packet_t * unsafe)client_state.fifo[rd_index];
          ethernet_packet_info_t info;
          info.type = ETH_DATA;
          info.src_ifnum = 0; // There is only one RGMII port
          info.timestamp = buf->timestamp;
          info.len = buf->length;
          info.filter_data = buf->filter_data;
          memcpy(&desc, &info, sizeof(info));
          memcpy(data, buf->data, buf->length);
          if (mii_get_and_dec_transmit_count(buf) == 0) {
            buffers_free_add(free_buffers, buf);
          }

          client_state.rd_index = increment_and_wrap_power_of_2(client_state.rd_index,
                                                                ETHERNET_RX_CLIENT_QUEUE_SIZE);

          if (client_state.rd_index != client_state.wr_index) {
            i_rx_lp[i].packet_ready();
          }
        }
        else {
          desc.type = ETH_NO_DATA;
        }
        break;

    case c_status_update :> link_status:
      for (int i = 0; i < n_rx_lp; i += 1) {
        if (client_state_lp[i].status_update_state == STATUS_UPDATE_WAITING) {
          client_state_lp[i].status_update_state = STATUS_UPDATE_PENDING;
          i_rx_lp[i].packet_ready();
        }
      }
      break;

      case c_speed_change :> unsigned tmp:
        done = 1;
        break;

      default:
        break;
    }

    if (done)
      break;

    // Loop until all high priority packets have been handled
    while (1) {
      if (buffers_used_empty(used_buffers_rx_hp))
        break;

      mii_packet_t * unsafe buf = (mii_packet_t *)buffers_used_take(used_buffers_rx_hp,
                                                                    RGMII_MAC_BUFFER_COUNT_RX);

      if (!isnull(c_rx_hp)) {
        ethernet_packet_info_t info;
        info.type = ETH_DATA;
        info.src_ifnum = 0;
        info.timestamp = buf->timestamp;
        info.len = buf->length;
        info.filter_data = buf->filter_data;
        sout_char_array(c_rx_hp, (char *)&info, sizeof(info));
        sout_char_array(c_rx_hp, (char *)buf->data, buf->length);
      }
      buffers_free_add(free_buffers, buf);
    }

    handle_incoming_packet(client_state_lp, i_rx_lp, n_rx_lp, used_buffers_rx_lp, free_buffers);

    if (buffers_free_available(free_buffers) <= RGMII_RX_BUFFERS_THRESHOLD) {
      drop_lp_packets(client_state_lp, n_rx_lp, used_buffers_rx_lp, free_buffers);
    }
  }
}

unsafe void rgmii_ethernet_tx_server_aux(tx_client_state_t client_state_lp[n_tx_lp],
                                         server ethernet_tx_if i_tx_lp[n_tx_lp], unsigned n_tx_lp,
                                         streaming chanend ? c_tx_hp,
                                         streaming chanend c_tx_to_mac,
                                         streaming chanend c_speed_change,
                                         buffers_used_t &used_buffers_tx,
                                         buffers_free_t &free_buffers)
{
  set_core_fast_mode_on();

  int sender_count = 0;
  int work_pending = 0;
  int done = 0;

  // If the acknowledge path is not given some priority then the TX packets can end up
  // continually being received but not being able to be sent on to the MAC
  int prioritize_ack = 0;

  // Acquire a free buffer to store high priority packets if needed
  mii_packet_t * unsafe tx_buf_hp = isnull(c_tx_hp) ? null : buffers_free_take(free_buffers);

  while (!done) {
    if (prioritize_ack)
      prioritize_ack--;

    select {
      case i_tx_lp[int i]._init_send_packet(unsigned n, unsigned dst_port):
        if (client_state_lp[i].send_buffer == null)
          client_state_lp[i].requested_send_buffer_size = 1;
        break;

      [[independent_guard]]
      case (int i = 0; i < n_tx_lp; i++)
        (client_state_lp[i].has_outgoing_timestamp_info) =>
        i_tx_lp[i]._get_outgoing_timestamp() -> unsigned timestamp:
        timestamp = client_state_lp[i].outgoing_timestamp;
        client_state_lp[i].has_outgoing_timestamp_info = 0;
        break;

      [[independent_guard]]
      case (int i = 0; i < n_tx_lp; i++)
        (client_state_lp[i].send_buffer != null && !prioritize_ack) =>
         i_tx_lp[i]._complete_send_packet(char data[n], unsigned n,
                                       int request_timestamp,
                                       unsigned dst_port):

        mii_packet_t * unsafe buf = client_state_lp[i].send_buffer;
        unsigned * unsafe dptr = &buf->data[0];
        memcpy(buf->data, data, n);
        buf->length = n;
        if (request_timestamp)
          buf->timestamp_id = i+1;
        else
          buf->timestamp_id = 0;
        work_pending++;
        buffers_used_add(used_buffers_tx, buf, RGMII_MAC_BUFFER_COUNT_TX);
        buf->tcount = 0;
        client_state_lp[i].send_buffer = null;
        client_state_lp[i].requested_send_buffer_size = 0;
        prioritize_ack += 2;
        break;

      case (tx_buf_hp && !prioritize_ack) => c_tx_hp :> unsigned n_bytes:
        sin_char_array(c_tx_hp, (char *)tx_buf_hp->data, n_bytes);
        work_pending++;
        tx_buf_hp->length = n_bytes;
        buffers_used_add(used_buffers_tx, tx_buf_hp, RGMII_MAC_BUFFER_COUNT_TX);
        tx_buf_hp->tcount = 0;
        tx_buf_hp = buffers_free_take(free_buffers);
        prioritize_ack += 2;
        break;

      case c_tx_to_mac :> uintptr_t buffer: {
        sender_count--;
        mii_packet_t *buf = (mii_packet_t *)buffer;
        if (buf->timestamp_id) {
          size_t client_id = buf->timestamp_id - 1;
          client_state_lp[client_id].has_outgoing_timestamp_info = 1;
          client_state_lp[client_id].outgoing_timestamp = buf->timestamp;
        }
        buffers_free_add(free_buffers, buf);
        break;
      }

      case c_speed_change :> unsigned tmp:
        done = 1;
        break;

      default:
        break;
    }

    if (work_pending && (sender_count < 2)) {
      // Send a pointer out to the outputter
      c_tx_to_mac <: (uintptr_t)buffers_used_take(used_buffers_tx, RGMII_MAC_BUFFER_COUNT_TX);
      work_pending--;
      sender_count++;
    }

    // Ensure there is always a high priority buffer
    if (!isnull(c_tx_hp) && (tx_buf_hp == null)) {
      tx_buf_hp = buffers_free_take(free_buffers);
    }

    for (int i = 0; i < n_tx_lp; i++) {
      if (client_state_lp[i].requested_send_buffer_size != 0 && client_state_lp[i].send_buffer == null) {
        client_state_lp[i].send_buffer = buffers_free_take(free_buffers);
      }
    }
  }

  empty_channel(c_tx_to_mac);
  if (!isnull(c_tx_hp)) {
    empty_channel(c_tx_hp);
  }
}

unsafe void rgmii_ethernet_config_server_aux(rx_client_state_t client_state_lp[n_rx_lp],
                                             unsigned n_rx_lp,
                                             server ethernet_cfg_if i_cfg[n],
                                             unsigned n,
                                             streaming chanend c_status_update,
                                             streaming chanend c_speed_change,
                                             volatile int * unsafe p_idle_slope)
{
  set_core_fast_mode_on();

  char mac_address[6] = {0};
  ethernet_link_state_t link_status = ETHERNET_LINK_DOWN;
  int done = 0;
  while (!done) {
    select {
      case i_cfg[int i].get_macaddr(size_t ifnum, char r_mac_address[6]):
        memcpy(r_mac_address, mac_address, 6);
        break;

      case i_cfg[int i].set_macaddr(size_t ifnum, char r_mac_address[6]):
        memcpy(mac_address, r_mac_address, 6);
        break;

      case i_cfg[int i].set_link_state(int ifnum, ethernet_link_state_t status):
        if (link_status != status) {
          link_status = status;
          c_status_update <: status;
        }
        break;

      case i_cfg[int i].add_macaddr_filter(size_t client_num, int is_hp,
                                           ethernet_macaddr_filter_t entry) ->
                                             ethernet_macaddr_filter_result_t result:
        result = mii_macaddr_hash_table_add_entry(client_num, is_hp, entry);
        break;

      case i_cfg[int i].del_macaddr_filter(size_t client_num, int is_hp,
                                           ethernet_macaddr_filter_t entry):
        mii_macaddr_hash_table_delete_entry(client_num, is_hp, entry);
        break;

      case i_cfg[int i].del_all_macaddr_filters(size_t client_num, int is_hp):
        mii_macaddr_hash_table_clear();
        break;

      case i_cfg[int i].add_ethertype_filter(size_t client_num, int is_hp, uint16_t ethertype):
        if (is_hp)
          fail("Standard MII ethernet does not support the high priority queue");

        rx_client_state_t &client_state = client_state_lp[client_num];
        size_t n = client_state.num_etype_filters;
        assert(n < ETHERNET_MAX_ETHERTYPE_FILTERS);
        client_state.etype_filters[n] = ethertype;
        client_state.num_etype_filters = n + 1;
        break;

      case i_cfg[int i].del_ethertype_filter(size_t client_num, int is_hp, uint16_t ethertype):
        if (is_hp)
          fail("Standard MII ethernet does not support the high priority queue");

        rx_client_state_t &client_state = client_state_lp[client_num];
        size_t j = 0;
        size_t n = client_state.num_etype_filters;
        while (j < n) {
          if (client_state.etype_filters[j] == ethertype) {
            client_state.etype_filters[j] = client_state.etype_filters[n-1];
            n--;
          }
          else {
            j++;
          }
        }
        client_state.num_etype_filters = n;
        break;

      case i_cfg[int i].get_tile_id_and_timer_value(unsigned &tile_id, unsigned &time_on_tile): {
        tile_id = get_tile_id_from_chanend(c_speed_change);
  
        timer tmr;
        tmr :> time_on_tile;
        break;
      }

      case i_cfg[int i].set_tx_qav_idle_slope(unsigned slope): {
        *p_idle_slope = slope;
        break;
      }

      case c_speed_change :> unsigned tmp:
        done = 1;
        break;
    }
  }
}
