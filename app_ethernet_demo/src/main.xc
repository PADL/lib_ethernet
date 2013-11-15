// Copyright (c) 2011, XMOS Ltd, All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

/*************************************************************************
 *
 * Ethernet ARP/ICMP demo
 * Note: Only supports unfragmented IP packets
 *
 *************************************************************************/
#include <xs1.h>
#include <platform.h>
#include "otp_board_info.h"
#include "mii_ethernet.h"
#include "ethernet_board_support.h"
#include "ethernet_phy_support.h"
#include "icmp.h"

// These ports are for accessing the OTP memory
on tile[XMOS_DEV_BOARD_ETH_TILE]:otp_ports_t otp_ports = OTP_PORTS_INITIALIZER;

// Here are the port definitions required by ethernet
// The intializers are taken from the ethernet_board_support.h header for
// XMOS dev boards. If you are using a different board you will need to
// supply explicit port structure intializers for these values
smi_ports_t smi_ports = XMOS_DEV_BOARD_SMI_PORTS;
mii_ports_t mii_ports = XMOS_DEV_BOARD_MII_PORTS(XS1_CLKBLK_1, XS1_CLKBLK_2);
ethernet_reset_port_t p_phy_reset = XMOS_DEV_BOARD_RESET_PORT;
port p_mii_timing = on tile[XMOS_DEV_BOARD_ETH_TILE]: XS1_PORT_8C;


static unsigned char ip_address[4] = {192, 168, 1, 178};


// An enum to manager the array of connections from the ethernet component
// to its clients.
enum eth_clients {
  ETH_TO_ICMP,
  NUM_ETH_CLIENTS
};

int main()
{
  ethernet_if i_eth[NUM_ETH_CLIENTS];
  ethernet_config_if i_eth_config;
  ethernet_filter_if i_eth_filter;
  par {
      on tile[XMOS_DEV_BOARD_ETH_TILE]:
      {
        char mac_address[6];
        otp_board_info_get_mac(otp_ports, 0, mac_address);
        if (USE_MII_LITE) {
          #define RX_MEM_SIZE_LITE 3200
          mii_ethernet_lite_server(i_eth_filter, i_eth_config,
                                   i_eth, NUM_ETH_CLIENTS,
                                   mac_address,
                                   mii_ports,
                                   p_mii_timing,
                                   RX_MEM_SIZE_LITE);
        } else {
          #define RX_MEM_SIZE 4096
          #define TX_MEM_SIZE 2048
          #define RX_HP_MEM_SIZE 0 // not using the high priority queue
          #define TX_HP_MEM_SIZE 0 // not using the high priority queue
          #define ENABLE_SHAPER  0 // not using traffic shaper
          mii_ethernet_server(i_eth_filter, i_eth_config,
                              i_eth, NUM_ETH_CLIENTS,
                              mac_address,
                              mii_ports,
                              RX_MEM_SIZE, TX_MEM_SIZE,
                              RX_HP_MEM_SIZE,
                              TX_HP_MEM_SIZE,
                              ENABLE_SHAPER);
        }
      }

      on tile[XMOS_DEV_BOARD_ETH_TILE]:
        smsc_LAN8710_driver(smi_ports, p_phy_reset,
                            i_eth_config,
                            XMOS_DEV_BOARD_PHY_ADDRESS);

      on tile[XMOS_DEV_BOARD_ETH_TILE]:
         arp_ip_filter(i_eth_filter);

      on tile[1]: icmp_server(i_eth[ETH_TO_ICMP], ip_address);
  }
  return 0;
}

