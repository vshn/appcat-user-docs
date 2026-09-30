#!/bin/sh
# A built image proves nothing: run it and ask it for a page.
#
# Usage: smoke.sh <image> <start-page-path> <text the page must contain>
#
# 127.0.0.1 rather than localhost: nginx listens on IPv4 only and busybox wget tries ::1 first,
# which answers "Connection refused" and reads like a container that never started.
#
# This catches what a green build cannot: an empty or half-copied site, an nginx config the
# container refuses to start with, assets the page references but the image does not carry.
set -e

IMAGE=$1
PAGE=${2:-/index.html}
EXPECT=$3
NAME=smoke-$$

[ -n "$IMAGE" ] || { echo "usage: smoke.sh <image> <path> <expected text>"; exit 2; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" "$IMAGE" >/dev/null
# shellcheck disable=SC2064
trap "docker rm -f $NAME >/dev/null 2>&1 || true" EXIT INT TERM

i=0
until docker exec "$NAME" wget -q -O /dev/null "http://127.0.0.1:8080$PAGE"; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then
    echo "ERROR: the container never served $PAGE"
    docker logs "$NAME" 2>&1 | tail -20
    exit 1
  fi
  sleep 1
done
echo "the container serves $PAGE"

page=$(docker exec "$NAME" wget -q -O- "http://127.0.0.1:8080$PAGE")

if [ -n "$EXPECT" ]; then
  echo "$page" | grep -q "$EXPECT" || {
    echo "ERROR: $PAGE does not contain \"$EXPECT\", so this is not the site we meant to build"
    exit 1
  }
  echo "$PAGE contains \"$EXPECT\""
fi

# The page names its stylesheet; the image has to actually carry it. A site built against a UI
# bundle that did not unpack renders as unstyled text and still returns 200.
css=$(echo "$page" | sed -n 's|.*href="[^"]*\(_/css/[^"]*\.css\)".*|\1|p' | head -1)
if [ -n "$css" ]; then
  docker exec "$NAME" wget -q -O /dev/null "http://127.0.0.1:8080/$css" || {
    echo "ERROR: $PAGE references /$css but the image does not serve it"
    exit 1
  }
  echo "the stylesheet it references is served: /$css"
else
  echo "ERROR: $PAGE references no UI stylesheet, so the UI bundle did not reach the build"
  exit 1
fi

# Browsers read the OpenSearch descriptor to offer this site as a search engine, and its Url
# template names the page a search lands on. Two sites in this estate advertised a search page
# that had been a 404 for years, because nothing ever asked.
# The start page says whether the site offers one: a <link rel="search"> in its head. If it does,
# the descriptor it names MUST be served, and a 404 is a failure, because that is exactly what a
# browser sees. A check that skipped whenever nothing was served let a site whose nginx location
# had no root advertise a descriptor that was a 404 in production. Only a page that advertises no
# descriptor at all skips this check.
link=$(echo "$page" | grep -o '<link[^>]*rel="search"[^>]*>' | head -1 || true)
descpath=/opensearchdescription.xml
if [ -n "$link" ]; then
  href=$(echo "$link" | sed -n 's|.*href="\([^"]*\)".*|\1|p' | sed -e 's|^[a-z]*://[^/]*||' -e 's|?.*||')
  [ -z "$href" ] || descpath=$href
  case "$descpath" in /*) ;; *) descpath=/$descpath ;; esac
fi
desc=$(docker exec "$NAME" wget -q -O- "http://127.0.0.1:8080$descpath" 2>/dev/null || true)
if [ -z "$desc" ]; then
  if [ -n "$link" ]; then
    echo "ERROR: $PAGE links a search descriptor at $descpath but the image does not serve it"
    exit 1
  fi
  echo "the page advertises no search descriptor, skipping the OpenSearch check"
else
  # An nginx default page or an HTML error page is not XML and must not pass as a descriptor.
  echo "$desc" | grep -q "<OpenSearchDescription" || {
    echo "ERROR: $descpath does not contain <OpenSearchDescription, so it is not a descriptor"
    exit 1
  }
  # The template is https://host/some/path.html?q={searchTerms}: keep only the path.
  search=$(echo "$desc" | sed -n 's|.*template="\([^"]*\)".*|\1|p' | head -1 |
    sed -e 's|^[a-z]*://[^/]*||' -e 's|?.*||')
  [ -n "$search" ] || {
    echo "ERROR: $descpath has no Url template with a path, so browsers cannot search with it"
    exit 1
  }
  docker exec "$NAME" wget -q -O /dev/null "http://127.0.0.1:8080$search" || {
    echo "ERROR: the search descriptor sends searches to $search but the image does not serve it"
    exit 1
  }
  echo "the search page the descriptor names is served: $search"
fi

# A missing page must be a 404 from this site, not a 500 or an nginx default page.
code=$(docker exec "$NAME" wget -S -q -O /dev/null "http://127.0.0.1:8080/definitely-not-a-page.html" 2>&1 |
  sed -n 's|.*HTTP/1.1 \([0-9]*\).*|\1|p' | head -1)
[ "$code" = "404" ] || { echo "ERROR: a missing page answered $code, not 404"; exit 1; }
echo "a missing page answers 404"

echo "smoke test passed"
