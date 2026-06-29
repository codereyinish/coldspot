# The network the ColdSpot exit needs: a VCN, a public subnet reachable from the
# internet (internet gateway + route), and a firewall (security list) that opens
# SSH (so you can log in / install.sh can reach it) and the exit's TCP port.

resource "oci_core_vcn" "coldspot" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "coldspot-vcn"
  dns_label      = "coldspot"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.coldspot.id
  display_name   = "coldspot-igw"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.coldspot.id
  display_name   = "coldspot-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.coldspot.id
  display_name   = "coldspot-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH — so you can log in and install.sh can SSH in to fetch the cert + creds.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6" # TCP
    tcp_options {
      min = 22
      max = 22
    }
  }

  # The ColdSpot exit (SOCKS5 over TLS). Open to 0.0.0.0/0 because the phone's
  # cellular IP keeps changing and can't be pinned — the exit's password is what
  # restricts use to your Mac (see server/exit.py).
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6" # TCP
    tcp_options {
      min = var.exit_port
      max = var.exit_port
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.coldspot.id
  cidr_block        = "10.0.0.0/24"
  display_name      = "coldspot-subnet"
  dns_label         = "sub"
  route_table_id    = oci_core_route_table.rt.id
  security_list_ids = [oci_core_security_list.sl.id]
}
