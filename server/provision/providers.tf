# The OCI provider authenticates with the API key that `provision.sh` sets up via
# `oci setup bootstrap` (browser login → ~/.oci/config). We read it by profile
# name — no secrets live in this repo. Region is NOT set here on purpose: the
# provider reads it from the profile, so there's nothing to paste. (Terraform
# talks to the OCI REST API directly through this provider; it does NOT shell out
# to the `oci` CLI.)
provider "oci" {
  config_file_profile = var.oci_profile
}
