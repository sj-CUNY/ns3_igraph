// Parameters:
// my_GUID
// topo_file - GUID-based topology file 
// core_dev
// GNRS_server_port - listening port on server, assumes localhost gnrs
// GNRS_listen_ip - IP assoc w/ interface GNRS listens on
// GNRS_listen_port - response listening port for gnrs clients
// file_to_send - full path of file to send
// src_GUID - Value in source GUID field
// dst_GUID - GUID of destination
// chk_pkt_count - no. of pkts per chunk
// chk_delay - inter chunk spacing

// Maintains router-wide resource stats, etc. 
routerstats::MF_RouterStats;

//Control path elements
//TODO remove this
arp_tbl::MF_ARPTable;
nbr_tbl::MF_NeighborTable();
rtg_tbl::MF_RoutingTable(MY_GUID $my_GUID, NEIGHBOR_TABLE nbr_tbl);
lp_hndlr::MF_LinkProbeHandler(MY_GUID $my_GUID, NEIGHBOR_TABLE nbr_tbl, ROUTING_TABLE rtg_tbl, ARP_TABLE arp_tbl, ETHER_TYPE 0x27C0, SRC $core_dev);
lsa_hndlr::MF_LSAHandler(MY_GUID $my_GUID, NEIGHBOR_TABLE nbr_tbl, ROUTING_TABLE rtg_tbl)

//Data path elements
//TODO why arp table?
agg::MF_Aggregator(ARP_TABLE arp_tbl, ROUTER_STATS routerstats);
cache_mngr::MF_CacheManager;
//TOOD forwarding table shouldn't be needed here. Simply tag all available NA options 
net_binder::MF_NetworkBinder(MY_GUID $my_GUID, FORWARDING_TABLE rtg_tbl, CACHE_MANAGER cache_mngr);
//TODO decouple forward table API from routing table element
intra_lkup::MF_IntraLookUp(MY_GUID $my_GUID, FORWARDING_TABLE rtg_tbl);
seg::MF_Segmentor(routerstats);

//enforces stated topology
topo_mngr::MF_TopologyManager(MY_GUID $my_GUID, TOPO_FILE $topo_file, ARP_TABLE arp_tbl);

//Counters and Statistics
//TODO: build a custom chunk counter to get proper data byte count
//incoming L2 pkt and byte count 
inCntr_pkt::Counter()
//incoming L3 chunk and byte count 
inCntr_chunk::Counter()
//outgoing L2 pkt and byte count 
outCntr_pkt::Counter

//Queues
inQ::ThreadSafeQueue(65535); //incoming L2 pkt Q
net_binderQ::ThreadSafeQueue(100); //chunk Q prior to NA resolution 
holdQ::Queue(100); //delayed chunk Q for destns w/ poor link/path conditions
outQ_ctrl::ThreadSafeQueue(100); //L2 outgoing high priority control pkt queue
outQ_data::Queue(65535); //L2 outgoing lower priority data pkt queue
outQ_sched::PrioSched; //priority sched for L2 pkts
outQ_core::Queue(65535); //L2 outgoing pkt Q for 'core' port
//outQ_edge::Queue(65535); //L2 outgoing pkt Q for 'edge' port

//L2 packet sources
//core port
fd_core::FromSimDevice($core_dev, PROMISC false, SNIFFER true);

//L3 chunk sources
//file-sourced data sender 
from_file::MF_FromFile(SRC_GUID $src_GUID, DST_GUID $dst_GUID, CHK_PKT_COUNT $chk_pkt_count, RESCHED_WAIT $resched_secs, ROUTER_STATS routerstats, FILENAME $file_to_send, CHUNK_DELAY $chk_delay); 

//L2 out i/f
td_core::ToSimDevice($core_dev);

fd_core -> SetTimestamp -> Paint(0, 16) -> inQ;

//start incoming pkt processing
inQ 	-> Unqueue
	-> topo_mngr
	-> inCntr_pkt
	//drop anything that isn't MF
	-> net_cla::Classifier(12/27C0, -);

net_cla[1] -> Discard;

net_cla[0] 
	-> Strip(14) // drop eth header
	-> mf_cla::Classifier(
			00/00000003, // p0 Link probe
			00/00000004, // p1 Link probe response
			00/00000005, // p2 LSA
			00/00000000, // p3 Data
			00/00000001, // p4 CSYN
			00/00000002, // p5 CSYN-ACK
			00/00000006, // p6 Client association
			00/00000007, // p7 Client dis-association 
			-);          // p8 Unhandled type, discard

mf_cla[6] -> Discard; // No client access in this config
mf_cla[7] -> Discard; // No client access in this config
mf_cla[8] -> Discard;

//routing control pkts

mf_cla[0] -> [0]lp_hndlr; // link probe
mf_cla[1] -> [1]lp_hndlr; // link probe ack
mf_cla[2] -> [0]lsa_hndlr; // lsa

//data and Hop signalling pkts

mf_cla[3] -> [0]agg; // data 
mf_cla[4] -> [1]agg; // csyn 
mf_cla[5] -> [1]seg; // csyn-ack

//Net-level processing for aggregated data blocks (chunks)

//chunk assembled from file source 
//TODO chunk count here to be accounted to 'host queued'
from_file 
	-> inCntr_chunk 
	-> net_binderQ;

//chunks assembled post Hop transfer from upstream node
agg[0] 
	-> inCntr_chunk 
	//chunk queue prior to NA resolution
	-> net_binderQ;

net_binderQ 
	-> Unqueue 
	-> [0]net_binder;

net_binder[0] -> intra_lkup;

//Forwarding decisions

intra_lkup[0] -> [0]seg; //send chunk to next hop
// Hold if (1) dest not found in FT or (2) poor net condns to dest
intra_lkup[1] -> holdQ; //no forwarding entry
intra_lkup[2] -> holdQ; //hold decision
 
//TODO: use a unified cache manager to hold delayed packets
//This is a hack for now that simply delays chunk processing by const. seconds 
//followed by rebinding
holdQ 
	-> DelayUnqueue(1) 
	-> net_binderQ;

//Outgoing csyn/csyn-ack pkts - place in high priority queue 
agg[1]
	//TODO: encap should happen just before ToDevice
	-> MF_EtherEncap(0x27C0, $core_dev, arp_tbl)
	-> outQ_ctrl;

//Outgoing data frame
seg[0]
	//TODO: encap should happen just before ToDevice
	-> MF_EtherEncap(0x27C0, $core_dev, arp_tbl)
	-> outQ_data;

//Rebind chunks that failed transfer to specified downstream node
seg[1] -> net_binderQ;

//Outgoing control pkts
lp_hndlr[0] //outgoing link probe
	//TODO unify encapsulation
	-> EtherEncap(0x27C0, $core_dev, ff:ff:ff:ff:ff:ff)
	-> outQ_ctrl;

lp_hndlr[1] //outgoing link probe ack
	-> EtherEncap(0x27C0, $core_dev, ff:ff:ff:ff:ff:ff)
	-> outQ_ctrl;

lsa_hndlr[0] //outgoing lsa
	-> EtherEncap(0x27C0, $core_dev, ff:ff:ff:ff:ff:ff)
	-> outQ_ctrl;

//priority schedule data and control pkts
outQ_ctrl -> [0]outQ_sched; 
outQ_data -> [1]outQ_sched; 

//to switch outgoing L2 pkts to respective learnt ports
out_switch::PaintSwitch(ANNO 16);
outQ_sched 
	-> outCntr_pkt 
	-> Unqueue 
	-> MF_DevColor(arp_tbl) 
	-> out_switch;

//Send pkts switch to corresponding to-devices
//port 0 is core bound

//core pkts
out_switch[0] -> outQ_core -> td_core;

//GNRS insert/update/query handling
//requestor --> request Q --> gnrs client --> gnrs svc
//gnrs svc --> response Q --> gnrs client --> requestor
//Component definitions
// gnrs request queue - multiple requestors
gnrs_reqQ::ThreadSafeQueue(100);
//gnrs client to interact with service
gnrs_rrh::GNRS_ReqRespHandler(MY_GUID $my_GUID, NET_ID "NA", RESP_LISTEN_IP $GNRS_listen_ip, RESP_LISTEN_PORT $GNRS_listen_port);
//UDP request sender 
gnrs_svc_sndr::Socket(UDP, $GNRS_server_ip, $GNRS_server_port);
//UDP response listener 
gnrs_svc_lstnr::Socket(UDP, 0.0.0.0, $GNRS_listen_port) 
//queue to hold responses from GNRS service
gnrs_respQ::Queue(100);

gnrs_reqQ -> Unqueue -> [0]gnrs_rrh;
//send requests to service
gnrs_rrh[0] -> gnrs_svc_sndr;
//recv & queue responses for processing & forwarding to requestors
gnrs_svc_lstnr -> gnrs_respQ -> Unqueue -> [1]gnrs_rrh;

//Requestor 2: Network binder
//Patch GNRS lookup requests/response from/to GNRS service client
net_binder[1] -> gnrs_reqQ;
gnrs_rrh[1] -> [1]net_binder;

//Thread/Task Scheduling
//re-balance tasks to threads every 10ms
//BalancedThreadSched(INTERVAL 10);
StaticThreadSched(fd_core 1, td_core 1, fd_edge 2, td_edge 2, rtg_tbl 3);