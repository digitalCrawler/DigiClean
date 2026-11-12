#!/bin/sh
# Vercel build for the landing page (Root Directory: website).
# Copies the static site to public/ and fills in what depends on where it
# is published:
#  - the GitHub repository whose releases the download buttons point at:
#    DIGICLEAN_REPO ("owner/name"), else the repository Vercel builds from;
#  - absolute social-preview URLs: SITE_URL ("https://example.com"), else
#    the project's production domain.
set -eu

rm -rf public
mkdir -p public
cp ./*.html public/
cp -R assets public/

repo="${DIGICLEAN_REPO:-}"
if [ -z "$repo" ] && [ "${VERCEL_GIT_PROVIDER:-}" = "github" ]; then
  repo="${VERCEL_GIT_REPO_OWNER}/${VERCEL_GIT_REPO_SLUG}"
fi
# Accept a pasted repository URL too: https://github.com/owner/name(.git)(/)
repo="${repo#https://}"; repo="${repo#http://}"; repo="${repo#www.}"
repo="${repo#github.com/}"; repo="${repo#git@github.com:}"
repo="${repo%/}"; repo="${repo%.git}"
case "$repo" in
  */*/* | *" "* | *:*) echo "error: DIGICLEAN_REPO must look like owner/name, got '$repo'" >&2; exit 1 ;;
esac
if [ -n "$repo" ]; then
  sed -i "s|__GITHUB_REPOSITORY__|${repo}|g" public/*.html
  echo "Download links point at github.com/${repo}/releases"
else
  echo "warning: no GitHub repository known; download buttons stay inactive (set DIGICLEAN_REPO)" >&2
fi

site="${SITE_URL:-}"
if [ -z "$site" ] && [ -n "${VERCEL_PROJECT_PRODUCTION_URL:-}" ]; then
  site="https://${VERCEL_PROJECT_PRODUCTION_URL}"
fi
if [ -n "$site" ]; then
  site="${site%/}"
  sed -i "s|content=\"assets/og-image.png\"|content=\"${site}/assets/og-image.png\"|" public/index.html
  sed -i "s|<meta property=\"og:type\" content=\"website\">|<meta property=\"og:type\" content=\"website\">\n  <meta property=\"og:url\" content=\"${site}/\">\n  <link rel=\"canonical\" href=\"${site}/\">|" public/index.html
  echo "Social previews use ${site}"
fi
