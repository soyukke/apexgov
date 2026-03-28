#!/usr/bin/env bash
# generate-picklist-registry.sh
#
# Scan Salesforce metadata XML files for picklist field definitions and
# generate a Java class that registers them with Schema.registerPicklist().
#
# Usage:
#   ./generate-picklist-registry.sh <project-root> <output-java-file>
#
# <project-root> is the Salesforce project root (parent of force-app/ or
# similar source directories).  The script searches recursively for
# objects/*/fields/*.field-meta.xml files containing <type>Picklist</type>.

set -euo pipefail

project_root="${1:?Usage: $0 <project-root> <output-java-file>}"
output_file="${2:?Usage: $0 <project-root> <output-java-file>}"

# Collect all picklist field metadata files.
picklist_files=()
while IFS= read -r -d '' f; do
  # Check if the file contains a Picklist or MultiselectPicklist type.
  if grep -qiE '<type>(Picklist|MultiselectPicklist)</type>' "$f" 2>/dev/null; then
    picklist_files+=("$f")
  fi
done < <(find "$project_root" -path "*/objects/*/fields/*.field-meta.xml" -print0 2>/dev/null)

if [ ${#picklist_files[@]} -eq 0 ]; then
  echo "No picklist fields found — skipping registry generation."
  exit 0
fi

# Ensure output directory exists.
mkdir -p "$(dirname "$output_file")"

# Start generating Java source.
{
  echo "package generated;"
  echo ""
  echo "import apexemu.runtime.Schema;"
  echo ""
  echo "public final class PicklistRegistry {"
  echo "  private PicklistRegistry() {}"
  echo ""
  echo "  public static void register() {"

  for f in "${picklist_files[@]}"; do
    # Extract object name and field name from the path:
    #   .../objects/<ObjectName>/fields/<FieldName>.field-meta.xml
    field_file="$(basename "$f")"
    field_name="${field_file%.field-meta.xml}"

    # Walk up to find the object name.
    fields_dir="$(dirname "$f")"
    object_dir="$(dirname "$fields_dir")"
    object_name="$(basename "$object_dir")"

    # Extract picklist values from <fullName> elements inside <value> blocks.
    # We use a simple approach: find all <fullName>...</fullName> lines that
    # are children of <value> elements (inside <valueSet> or <valueSetDefinition>).
    values=()
    in_value=false
    while IFS= read -r line; do
      trimmed="$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
      if echo "$trimmed" | grep -qi '<value>'; then
        in_value=true
      fi
      if echo "$trimmed" | grep -qi '</value>'; then
        in_value=false
      fi
      if $in_value; then
        # Extract fullName content.
        if echo "$trimmed" | grep -qi '<fullName>'; then
          val="$(echo "$trimmed" | sed 's/.*<fullName>//I' | sed 's/<\/fullName>.*//')"
          # Decode XML entities.
          val="$(echo "$val" | sed "s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&apos;/'/g; s/&quot;/\"/g")"
          values+=("$val")
        fi
      fi
    done < "$f"

    if [ ${#values[@]} -gt 0 ]; then
      # Build the Java call, escaping strings for Java.
      printf '    Schema.registerPicklist("%s", "%s"' "$object_name" "$field_name"
      for v in "${values[@]}"; do
        # Escape backslashes and double quotes for Java string literals.
        escaped="$(echo "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf ', "%s"' "$escaped"
      done
      echo ");"
    fi
  done

  echo "  }"
  echo "}"
} > "$output_file"

echo "Generated picklist registry: $output_file (${#picklist_files[@]} picklist fields found)"
