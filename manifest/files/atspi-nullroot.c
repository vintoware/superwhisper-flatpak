/*
 * atspi-nullroot — LD_PRELOAD workaround for a libatspi crash in at-spi2-core
 * 2.62.0–2.62.1 (GNOME 51). env.sh preloads it only on those versions; see AGENTS.md.
 *
 * When a host app's direct AT-SPI socket can't be opened, handle_get_bus_address()
 * calls atspi_accessible_get_process_id (app->root, NULL) to word a warning. In a
 * Flatpak the socket ($XDG_RUNTIME_DIR/at-spi2-XXXXXX/socket on the host) never
 * exists, and if the app's root isn't known yet (its first event came from a child,
 * as xdg-desktop-portal-gtk's does at login) root is NULL and libatspi segfaults.
 * Upstream fix, same semantics as here: at-spi2-core commit 22c0d877
 * ("Don't crash when a direct connection fails before the root is known").
 *
 * libatspi calls the function through its PLT, so this definition wins. The real
 * one is looked up in the already-loaded libatspi: PyGObject dlopens it RTLD_LOCAL,
 * where dlsym(RTLD_NEXT) wouldn't find it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>

typedef unsigned int guint;
typedef guint (*get_process_id_fn) (void *accessible, void **error);

guint
atspi_accessible_get_process_id (void *accessible, void **error)
{
  static get_process_id_fn real;

  if (accessible == NULL)
    return (guint) -1;
  if (real == NULL)
    {
      void *lib = dlopen ("libatspi.so.0", RTLD_NOW | RTLD_NOLOAD);
      if (lib != NULL)
        real = (get_process_id_fn) dlsym (lib, "atspi_accessible_get_process_id");
    }
  return real != NULL ? real (accessible, error) : (guint) -1;
}
