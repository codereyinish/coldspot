# Tenancy-specific values. You normally DON'T touch these — `provision.sh` fills
# compartment_ocid and ssh_public_key in automatically (as TF_VAR_* env vars,
# read from ~/.oci/config and ~/.ssh) so there's nothing to paste. The optional
# overrides further down can go in terraform.tfvars if you want them. Nothing
# secret is committed. (Region isn't a variable: the provider reads it from your
# ~/.oci/config profile.)

variable "oci_profile" {
  description = "Profile name in ~/.oci/config to authenticate with"
  type        = string
  default     = "DEFAULT"
}

variable "compartment_ocid" {
  description = "OCID of the compartment to create resources in (root tenancy OCID, auto-supplied by provision.sh from ~/.oci/config)"
  type        = string
}

variable "ssh_public_key" {
  description = "Your SSH PUBLIC key text (auto-supplied by provision.sh from ~/.ssh/id_ed25519.pub) — added to the VM so you can log in"
  type        = string
}

variable "instance_shape" {
  # E2.1.Micro (AMD, 1 OCPU/1GB) is the default because it's reliably available
  # on Always-Free — plenty for a SOCKS exit. A1.Flex (Ampere ARM, up to 4 OCPU/24GB)
  # is more powerful but frequently fails apply with "Out of host capacity."
  description = "VM shape. Always-Free: VM.Standard.E2.1.Micro (AMD, reliable) or VM.Standard.A1.Flex (Ampere, bigger but often no capacity)."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_ocpus" {
  description = "OCPUs (only used by Flex shapes like A1.Flex). Always-Free A1 allows up to 4."
  type        = number
  default     = 1
}

variable "instance_memory_gb" {
  description = "Memory in GB (Flex shapes only). Always-Free A1 allows up to 24."
  type        = number
  default     = 6
}

variable "exit_port" {
  description = "TCP port the ColdSpot exit listens on (opened as an ingress rule). 443 looks like ordinary HTTPS and is widely reachable."
  type        = number
  default     = 443
}
