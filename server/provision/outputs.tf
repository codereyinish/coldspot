output "public_ip" {
  description = "The exit server's public IP — provision.sh hands this to install.sh"
  value       = oci_core_instance.exit.public_ip
}

output "ssh" {
  description = "Ready-made SSH command"
  value       = "ssh ubuntu@${oci_core_instance.exit.public_ip}"
}
