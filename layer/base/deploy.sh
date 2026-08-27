#!/bin/bash

set -eu

files=()

# Image assets
if [[ -n "${IGconf_image_outputdir:-}" ]] ; then
   pat="${IGconf_image_outputdir}/${IGconf_image_name:-}"*.${IGconf_image_suffix:-}
   if compgen -G "$pat" > /dev/null 2>&1; then
      for f in $pat ; do
         files+=("$f")
      done
   fi

   pat="${IGconf_image_outputdir}"/*.sparse
   if compgen -G "$pat" > /dev/null 2>&1; then
      for f in $pat ; do
         files+=("$f")
      done
   fi

   files+=("${IGconf_image_outputdir}/image.json")
fi

# Filesystem assets
[[ -f "$IGconf_target_path" ]] && files+=("$IGconf_target_path")
files+=("${IGconf_target_dir}/${IGconf_sbom_filename:-}")
files+=("${IGconf_target_dir}/manifest")
files+=("${IGconf_target_dir}/config.yaml")


# Assets belonging to the disk image are versioned on deployment so they remain
# identifiable once separated from the deploy directory. This matches the naming
# of the IDP archive below. Everything else keeps its build-time name.
deployname() {
   local base="${1##*/}"
   if [[ -n "${IGconf_image_name:-}" && -n "${IGconf_artefact_version:-}" \
         && "$base" == "${IGconf_image_name}".* ]] ; then
      printf '%s-%s.%s' "$IGconf_image_name" "$IGconf_artefact_version" \
         "${base#"${IGconf_image_name}".}"
   else
      printf '%s' "$base"
   fi
}


echo "Installing assets..."
mkdir -p "$IGconf_deploy_dir"
for f in "${files[@]}" ; do
   [[ -f "$f" ]] || continue
   out="${IGconf_deploy_dir}/$(deployname "$f")"
   case "$IGconf_deploy_compression" in
      zstd)
         zstd -v -f "$f" --sparse -o "${out}.zst"
         ;;
      none)
         cp -v --sparse=always "$f" "$out"
         ;;
      *)
         ;;
   esac
done


echo "Creating manifest..."
{
  echo "{"
  echo "  \"deployment_info\": {"
  echo "    \"version\": \"${IGconf_artefact_version:-}\","
  echo "    \"date\": \"$(date -Iseconds)\""
  echo "  },"
  echo "  \"files\": ["

  first=true
  for f in "$IGconf_deploy_dir"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "deployed.json" ]] && continue
    [[ "$first" == true ]] || echo ","
    first=false

    size=$(stat -c %s "$f")
    mime_type=$(file -b --mime-type "$f" 2>/dev/null || echo "unknown")

    echo "    {"
    echo "      \"name\": \"$(basename "$f")\","
    echo "      \"size\": $size,"
    echo "      \"mime_type\": \"$mime_type\","
    echo "      \"sha1\": \"$(sha1sum "$f" | cut -d' ' -f1)\""
    echo "    }"
  done

  echo "  ]"
  echo "}"
} > "$IGconf_deploy_dir/deployed.json"

# Create a .tar.zst IDP archive suitable for upload to rpi-sb-provisioner.
# Bundles uncompressed image.json + sparse images at the top level of the tar.
# Requires zstd, so only run when the compression scheme guarantees it is available.
if [[ "$IGconf_deploy_compression" == "zstd" ]] && [[ -f "${IGconf_image_outputdir}/image.json" ]]; then
    echo "Creating IDP archive..."
    idp_files=("image.json")
    for f in "${IGconf_image_outputdir}"/*.sparse; do
        [[ -f "$f" ]] && idp_files+=("$(basename "$f")")
    done

    archive_name="${IGconf_image_name:-image}-${IGconf_artefact_version:-unknown}.tar.zst"
    tar -C "${IGconf_image_outputdir}" -cf - "${idp_files[@]}" \
        | zstd -f -o "$IGconf_deploy_dir/$archive_name"
    echo "Created IDP archive: $IGconf_deploy_dir/$archive_name"
fi
