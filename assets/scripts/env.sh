# Shared environment for the mirage-prose scripts and agents. Nothing secret
# lives here: the scoped kubeconfig is a path (outside the repo), the beads
# door is a URL.
: "${HOME:=/Users/$(id -un)}"
export KUBECONFIG="${MIRAGE_PROSE_KUBECONFIG:-$HOME/k3s-beads/mirage-prose.kubeconfig}"
export MIRAGE_PROSE_BEADS="${MIRAGE_PROSE_BEADS:-http://127.0.0.1:8099}"
