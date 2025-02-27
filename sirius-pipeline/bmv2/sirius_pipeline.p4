#include <core.p4>
#include <v1model.p4>
#include "sirius_headers.p4"
#include "sirius_metadata.p4"
#include "sirius_parser.p4"
#include "sirius_vxlan.p4"
#include "sirius_outbound.p4"
#include "sirius_inbound.p4"
#include "sirius_conntrack.p4"

control sirius_verify_checksum(inout headers_t hdr,
                         inout metadata_t meta)
{
    apply { }
}

control sirius_compute_checksum(inout headers_t hdr,
                          inout metadata_t meta)
{
    apply { }
}

control sirius_ingress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t standard_metadata)
{
    action drop_action() {
        mark_to_drop(standard_metadata);
    }

    action deny() {
        meta.dropped = true;
    }

    action accept() {
    }

    @name("vip|dash")
    table vip {
        key = {
            hdr.ipv4.dst_addr : exact @name("hdr.ipv4.dst_addr:VIP");
        }

        actions = {
            accept;
            deny;
        }

        const default_action = deny;
    }

    action set_outbound_direction() {
        meta.direction = direction_t.OUTBOUND;
    }

    @name("direction_lookup|dash")
    table direction_lookup {
        key = {
            hdr.vxlan.vni : exact @name("hdr.vxlan.vni:VNI");
        }

        actions = {
            set_outbound_direction;
            deny;
        }
    }

    action set_appliance(EthernetAddress neighbor_mac,
                         EthernetAddress mac,
                         IPv4Address ip) {
        meta.encap_data.underlay_dmac = neighbor_mac;
        meta.encap_data.underlay_smac = mac;
        meta.encap_data.underlay_sip = ip;
    }

    table appliance {
        key = {
            meta.appliance_id : ternary @name("meta.appliance_id:appliance_id");
        }

        actions = {
            set_appliance;
        }
    }

    action set_eni_attrs(bit<32> cps,
                         bit<32> pps,
                         bit<32> flows) {
        meta.eni_data.cps   = cps;
        meta.eni_data.pps   = pps;
        meta.eni_data.flows = flows;
    }

    @name("eni|dash")
    table eni {
        key = {
            meta.eni_id : exact @name("meta.eni_id:eni_id");
        }

        actions = {
            set_eni_attrs;
        }
    }

    direct_counter(CounterType.packets_and_bytes) eni_counter;

    table eni_meter {
        key = {
            meta.eni_id : exact @name("meta.eni_id:eni_id");
            meta.direction : exact @name("meta.direction:direction");
            meta.dropped : exact @name("meta.dropped:dropped");
        }

        actions = { NoAction; }

        counters = eni_counter;
    }

    action permit() {
        meta.dropped = false;
    }

    action vxlan_decap_pa_validate() {}

    @name("pa_validation|dash_vnet")
    table pa_validation {
        key = {
            meta.eni_id: exact @name("meta.eni_id:eni_id");
            hdr.ipv4.src_addr : exact @name("hdr.ipv4.src_addr:sip");
            hdr.vxlan.vni : exact @name("hdr.vxlan.vni:VNI");
        }

        actions = {
            permit;
            @defaultonly deny;
        }

        const default_action = deny;
    }

    @name("inbound_routing|dash_vnet")
    table inbound_routing {
        key = {
            hdr.vxlan.vni : exact @name("hdr.vxlan.vni:VNI");
        }
        actions = {
            vxlan_decap(hdr);
            vxlan_decap_pa_validate;
            @defaultonly deny;
        }

        const default_action = deny;
    }

    action set_eni(bit<16> eni_id) {
        meta.eni_id = eni_id;
    }

    @name("eni_ether_address_map|dash")
    table eni_ether_address_map {
        key = {
            meta.eni_addr : exact @name("meta.eni_addr:address");
        }

        actions = {
            set_eni;
        }
    }

    apply {
        vip.apply();
        if (meta.dropped) {
            return;
        }

        meta.direction = direction_t.INBOUND;
        direction_lookup.apply();

        appliance.apply();

        /* Outer header processing */

        if (meta.direction == direction_t.OUTBOUND) {
            vxlan_decap(hdr);
        } else if (meta.direction == direction_t.INBOUND) {
            switch (inbound_routing.apply().action_run) {
                vxlan_decap_pa_validate: {
                    pa_validation.apply();
                    vxlan_decap(hdr);
                }
            }
        }

        meta.dst_ip_addr = 0;
        meta.is_dst_ip_v6 = 0;
        if (hdr.ipv6.isValid()) {
            meta.dst_ip_addr = hdr.ipv6.dst_addr;
            meta.is_dst_ip_v6 = 1;
        } else if (hdr.ipv4.isValid()) {
            meta.dst_ip_addr = (bit<128>)hdr.ipv4.dst_addr;
        }

        /* At this point the processing is done on customer headers */

        /* Put VM's MAC in the direction agnostic metadata field */
        meta.eni_addr = meta.direction == direction_t.OUTBOUND  ?
                                          hdr.ethernet.src_addr :
                                          hdr.ethernet.dst_addr;
        eni_ether_address_map.apply();
        eni.apply();

        if (meta.direction == direction_t.OUTBOUND) {
            outbound.apply(hdr, meta, standard_metadata);
        } else if (meta.direction == direction_t.INBOUND) {
            inbound.apply(hdr, meta, standard_metadata);
        }

        eni_meter.apply();

        /* Send packet to port 1 by default if we reached the end of pipeline */
        standard_metadata.egress_spec = 1;
    }
}

control sirius_egress(inout headers_t hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t standard_metadata)
{
    apply { }
}

V1Switch(sirius_parser(),
         sirius_verify_checksum(),
         sirius_ingress(),
         sirius_egress(),
         sirius_compute_checksum(),
         sirius_deparser()) main;
