# The VM itself. We look up an Ubuntu 22.04 image for the chosen shape, pick the
# first availability domain, and launch the instance on the public subnet with a
# public IP and your SSH key. Nothing is installed at boot — install.sh pushes
# setup.sh + exit.py over SSH afterwards (no GitHub fetch, no boot-time DNS race).

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "exit" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "coldspot-server"
  shape               = var.instance_shape

  # Flex shapes (e.g. A1.Flex) require ocpus/memory; fixed shapes (E2.1.Micro) reject it.
  dynamic "shape_config" {
    for_each = can(regex("Flex", var.instance_shape)) ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gb
    }
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
  }

  # Only the SSH key goes on the box at creation.
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}
