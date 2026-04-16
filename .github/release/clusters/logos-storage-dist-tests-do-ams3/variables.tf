variable "region" {
  description = "DigitalOcean region (e.g. ams3)"
  type        = string
}

variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}
