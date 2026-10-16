#!/usr/bin/env bash
set -euo pipefail

check() {
  if ! printf '%s' "$2" | LC_ALL=C grep -qE "$3"; then
    echo "::error::$1 형식이 올바르지 않다: $2"
    exit 1
  fi
}
tag_re='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
check image_name "$IMAGE_NAME" '^[a-z0-9][a-z0-9._/-]*$'
check source_tag "$SOURCE_TAG" "$tag_re"
read -ra tags <<< "$NEW_TAGS"
[ "${#tags[@]}" -gt 0 ] || { echo "::error::tags 가 비어 있다"; exit 1; }
for t in "${tags[@]}"; do check tags "$t" "$tag_re"; done

media_types=(
  application/vnd.oci.image.index.v1+json
  application/vnd.docker.distribution.manifest.list.v2+json
  application/vnd.oci.image.manifest.v1+json
  application/vnd.docker.distribution.manifest.v2+json
)

get_image() {
  aws ecr batch-get-image \
    --repository-name "$IMAGE_NAME" \
    --image-ids imageTag="$1" \
    --accepted-media-types "${media_types[@]}" \
    --output json
}

source=$(get_image "$SOURCE_TAG")
digest=$(jq -r '.images[0].imageId.imageDigest // empty' <<< "$source")
[ -n "$digest" ] || { echo "::error::이미지가 없다: $IMAGE_NAME:$SOURCE_TAG"; exit 1; }
manifest=$(jq -r '.images[0].imageManifest' <<< "$source")
media_type=$(jq -r '.images[0].imageManifestMediaType' <<< "$source")
echo "원본: $IMAGE_NAME:$SOURCE_TAG ($digest)"

to_add=()
for t in "${tags[@]}"; do
  existing=$(get_image "$t" | jq -r '.images[0].imageId.imageDigest // empty')
  if [ -z "$existing" ]; then
    to_add+=("$t")
  elif [ "$existing" = "$digest" ]; then
    echo "이미 붙어 있음: $IMAGE_NAME:$t"
  else
    echo "::error::$IMAGE_NAME:$t 가 이미 다른 이미지($existing)를 가리킨다"
    exit 1
  fi
done

for t in ${to_add[@]+"${to_add[@]}"}; do
  aws ecr put-image \
    --repository-name "$IMAGE_NAME" \
    --image-tag "$t" \
    --image-manifest "$manifest" \
    --image-manifest-media-type "$media_type" \
    --image-digest "$digest" > /dev/null
  echo "태그 추가: $IMAGE_NAME:$t"
done

echo "image_digest=$digest" >> "$GITHUB_OUTPUT"
