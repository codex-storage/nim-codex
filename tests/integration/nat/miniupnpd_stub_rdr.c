/* Stub firewall backend for miniupnpd.
 * Replaces iptcrdr.o + iptpinhole.o + nfct_get.o.
 * All mapping operations succeed without touching the kernel. */

#include <stdint.h>
#include <sys/socket.h>

/* commonrdr.h interface */

int init_redirect(void) { return 0; }
void shutdown_redirect(void) {}

int get_redirect_rule_count(const char *ifname)
{ (void)ifname; return 0; }

int get_redirect_rule(const char *ifname, unsigned short eport, int proto,
                      char *iaddr, int iaddrlen, unsigned short *iport,
                      char *desc, int desclen,
                      char *rhost, int rhostlen,
                      unsigned int *timestamp,
                      uint64_t *packets, uint64_t *bytes)
{ (void)ifname; (void)eport; (void)proto; (void)iaddr; (void)iaddrlen;
  (void)iport; (void)desc; (void)desclen; (void)rhost; (void)rhostlen;
  (void)timestamp; (void)packets; (void)bytes; return -1; }

int get_redirect_rule_by_index(int index,
                                char *ifname, unsigned short *eport,
                                char *iaddr, int iaddrlen, unsigned short *iport,
                                int *proto, char *desc, int desclen,
                                char *rhost, int rhostlen,
                                unsigned int *timestamp,
                                uint64_t *packets, uint64_t *bytes)
{ (void)index; (void)ifname; (void)eport; (void)iaddr; (void)iaddrlen;
  (void)iport; (void)proto; (void)desc; (void)desclen; (void)rhost;
  (void)rhostlen; (void)timestamp; (void)packets; (void)bytes; return -1; }

unsigned short *get_portmappings_in_range(unsigned short startport,
                                           unsigned short endport,
                                           int proto, unsigned int *number)
{ (void)startport; (void)endport; (void)proto; *number = 0; return 0; }

int update_portmapping(const char *ifname, unsigned short eport, int proto,
                       unsigned short iport, const char *desc,
                       unsigned int timestamp)
{ (void)ifname; (void)eport; (void)proto; (void)iport; (void)desc;
  (void)timestamp; return 0; }

int update_portmapping_desc_timestamp(const char *ifname,
                                       unsigned short eport, int proto,
                                       const char *desc, unsigned int timestamp)
{ (void)ifname; (void)eport; (void)proto; (void)desc; (void)timestamp;
  return 0; }

/* iptcrdr.h interface */

int add_redirect_rule2(const char *ifname,
                       const char *rhost, unsigned short eport,
                       const char *iaddr, unsigned short iport, int proto,
                       const char *desc, unsigned int timestamp)
{ (void)ifname; (void)rhost; (void)eport; (void)iaddr; (void)iport;
  (void)proto; (void)desc; (void)timestamp; return 0; }

int add_peer_redirect_rule2(const char *ifname,
                             const char *rhost, unsigned short rport,
                             const char *eaddr, unsigned short eport,
                             const char *iaddr, unsigned short iport, int proto,
                             const char *desc, unsigned int timestamp)
{ (void)ifname; (void)rhost; (void)rport; (void)eaddr; (void)eport;
  (void)iaddr; (void)iport; (void)proto; (void)desc; (void)timestamp;
  return 0; }

int add_filter_rule2(const char *ifname,
                     const char *rhost, const char *iaddr,
                     unsigned short eport, unsigned short iport,
                     int proto, const char *desc)
{ (void)ifname; (void)rhost; (void)iaddr; (void)eport; (void)iport;
  (void)proto; (void)desc; return 0; }

int delete_redirect_and_filter_rules(unsigned short eport, int proto)
{ (void)eport; (void)proto; return 0; }

int delete_filter_rule(const char *ifname, unsigned short port, int proto)
{ (void)ifname; (void)port; (void)proto; return 0; }

int add_peer_dscp_rule2(const char *ifname,
                         const char *rhost, unsigned short rport,
                         unsigned char dscp,
                         const char *iaddr, unsigned short iport, int proto,
                         const char *desc, unsigned int timestamp)
{ (void)ifname; (void)rhost; (void)rport; (void)dscp; (void)iaddr;
  (void)iport; (void)proto; (void)desc; (void)timestamp; return 0; }

int get_peer_rule_by_index(int index,
                            char *ifname, unsigned short *eport,
                            char *iaddr, int iaddrlen, unsigned short *iport,
                            int *proto, char *desc, int desclen,
                            char *rhost, int rhostlen, unsigned short *rport,
                            unsigned int *timestamp,
                            uint64_t *packets, uint64_t *bytes)
{ (void)index; (void)ifname; (void)eport; (void)iaddr; (void)iaddrlen;
  (void)iport; (void)proto; (void)desc; (void)desclen; (void)rhost;
  (void)rhostlen; (void)rport; (void)timestamp; (void)packets; (void)bytes;
  return -1; }

int get_nat_redirect_rule(const char *nat_chain_name, const char *ifname,
                           unsigned short eport, int proto,
                           char *iaddr, int iaddrlen, unsigned short *iport,
                           char *desc, int desclen,
                           char *rhost, int rhostlen,
                           unsigned int *timestamp,
                           uint64_t *packets, uint64_t *bytes)
{ (void)nat_chain_name; (void)ifname; (void)eport; (void)proto; (void)iaddr;
  (void)iaddrlen; (void)iport; (void)desc; (void)desclen; (void)rhost;
  (void)rhostlen; (void)timestamp; (void)packets; (void)bytes; return -1; }

int list_redirect_rule(const char *ifname)
{ (void)ifname; return 0; }

/* commonrdr.h USE_NETFILTER interface */

int set_rdr_name(int param, const char *string)
{ (void)param; (void)string; return 0; }

/* nfct_get.c interface */

int get_nat_ext_addr(struct sockaddr *src, struct sockaddr *dst, uint8_t proto,
                     struct sockaddr *ret_ext)
{ (void)src; (void)dst; (void)proto; (void)ret_ext; return -1; }

/* iptpinhole.h interface */

int find_pinhole(const char *ifname,
                 const char *rem_host, unsigned short rem_port,
                 const char *int_client, unsigned short int_port,
                 int proto, char *desc, int desc_len, unsigned int *timestamp)
{ (void)ifname; (void)rem_host; (void)rem_port; (void)int_client;
  (void)int_port; (void)proto; (void)desc; (void)desc_len; (void)timestamp;
  return -1; }

int add_pinhole(const char *ifname,
                const char *rem_host, unsigned short rem_port,
                const char *int_client, unsigned short int_port,
                int proto, const char *desc, unsigned int timestamp)
{ (void)ifname; (void)rem_host; (void)rem_port; (void)int_client;
  (void)int_port; (void)proto; (void)desc; (void)timestamp; return 0; }

int update_pinhole(unsigned short uid, unsigned int timestamp)
{ (void)uid; (void)timestamp; return 0; }

int delete_pinhole(unsigned short uid)
{ (void)uid; return 0; }

int get_pinhole_info(unsigned short uid,
                     char *rem_host, int rem_hostlen, unsigned short *rem_port,
                     char *int_client, int int_clientlen,
                     unsigned short *int_port,
                     int *proto, char *desc, int desclen,
                     unsigned int *timestamp,
                     uint64_t *packets, uint64_t *bytes)
{ (void)uid; (void)rem_host; (void)rem_hostlen; (void)rem_port;
  (void)int_client; (void)int_clientlen; (void)int_port; (void)proto;
  (void)desc; (void)desclen; (void)timestamp; (void)packets; (void)bytes;
  return -1; }

int get_pinhole_uid_by_index(int index)
{ (void)index; return -1; }

int clean_pinhole_list(unsigned int *next_timestamp)
{ (void)next_timestamp; return 0; }
