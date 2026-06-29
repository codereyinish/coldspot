# Terraform + OCI provider version pins. `terraform init` reads this and downloads
# the OCI provider plugin (the thing that actually makes the API calls).
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }
}
