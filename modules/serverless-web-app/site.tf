# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The site's files are published after apply by the pipeline, not by Terraform. Their digest is an input here,
# so a front-end-only change is a plan with changes, and a release proceeds only on a plan with changes.

locals {
  # The files the pipeline uploads: the container and local preview files are not part of the site.
  site_files = sort([for f in fileset(var.site_source_dir, "**") : f if !contains(var.site_excluded_files, f)])
}

# Each file's path and content hash, so an edit, a new file, a removal and a rename all change it.
resource "terraform_data" "site_content" {
  input = sha256(join("\n", [for f in local.site_files : "${f} ${filesha256("${var.site_source_dir}/${f}")}"]))
}
