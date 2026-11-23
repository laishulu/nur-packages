{ pkgs, stdenv, version }:

# LD_PRELOAD shims for the two vendor bugs that cannot be fixed anywhere else:
# the Shift key-up reported as Caps Lock when XKB's shift:both_capslock is on,
# and the display request that asks the guest for the local physical
# resolution.  Both are only loaded into the client's process tree.
{
  # The viewer turns every key into a keysym first, and Qt does that with the
  # *current* keyboard state:  `xkb_state_key_get_one_sym(state, keycode)`.
  # A key-release event arrives while the modifier it releases is still down,
  # so the "shifted" level of the key is selected.  Normally that level is the
  # same symbol; with the common XKB option `shift:both_capslock` (KDE: "Both
  # Shift keys together enable Caps Lock") it is not:
  #
  #     key <LFSH> { [ Shift_L, Caps_Lock ] };
  #     key <RTSH> { [ Shift_R, Caps_Lock ] };
  #
  # and pressing then releasing Shift yields
  #
  #     Shift press    -> 0xffe1 Shift_L
  #     Shift release  -> 0xffe5 Caps_Lock     <-- should be Shift_L
  #
  # The client therefore believes the Shift key-up is a Caps Lock event, sends
  # a Caps-Lock scan code (58) instead of the Shift one (42), and the guest
  # keeps Shift latched: lowercase letters come out uppercase and the digit row
  # becomes !@#$ until the client reconnects.  Only modifiers are affected --
  # they are the only keys with such a dual mapping.
  #
  # Reproduce it on the live display / with libxkbcommon directly:
  #   setxkbmap -print | grep both_capslock
  #   xmodmap -pke | grep 'keycode  50'        # Shift_L Caps_Lock
  #
  # Fix: a small LD_PRELOAD shim loaded into the client only.  It wraps
  # `xkb_state_key_get_one_sym` and, when that resolves a key to a lock symbol
  # while the key's *base* (level-0) symbol is a modifier, reports the base
  # symbol instead.  This is the single funnel for the keysym on both paths the
  # viewer uses (the grabbed-key path that re-injects the event into Qt, and the
  # plain focus path where Qt handles the event itself), and character keys are
  # never touched, so Shift+<letter> keeps its shifted symbol.  Nothing in the
  # vendor binaries is modified; CMCC_NO_KB_FIX=1 disables it.
  keyboardFix = stdenv.mkDerivation {
    pname = "cmcc-jtydn-keyboard-fix";
    inherit version;

    dontUnpack = true;
    buildInputs = [ pkgs.libxkbcommon ];

    buildPhase = ''
      runHook preBuild
      cat > kbd-shim.c <<'EOF'
      #define _GNU_SOURCE
      #include <dlfcn.h>
      #include <stdarg.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <unistd.h>
      #include <xkbcommon/xkbcommon.h>

      /* CMCC_DEBUG_SHIM=1 makes both shims append to /tmp/cmcc-shim.log and to
       * stderr, so a run can be checked afterwards. */
      static void shim_log(const char *fmt, ...)
      {
        va_list ap;
        FILE *f;

        if (!getenv("CMCC_DEBUG_SHIM"))
          return;
        f = fopen("/tmp/cmcc-shim.log", "a");
        if (f) {
          va_start(ap, fmt);
          vfprintf(f, fmt, ap);
          va_end(ap);
          fputc('\n', f);
          fclose(f);
        }
        va_start(ap, fmt);
        vfprintf(stderr, fmt, ap);
        va_end(ap);
        fputc('\n', stderr);
      }

      __attribute__((constructor)) static void shim_init(void)
      {
        shim_log("keyboard shim loaded (pid %d)", (int)getpid());
      }

      typedef xkb_keysym_t (*one_sym_fn)(struct xkb_state *, xkb_keycode_t);

      static int is_modifier(xkb_keysym_t s)
      {
        switch (s) {
        case XKB_KEY_Shift_L: case XKB_KEY_Shift_R:
        case XKB_KEY_Control_L: case XKB_KEY_Control_R:
        case XKB_KEY_Meta_L: case XKB_KEY_Meta_R:
        case XKB_KEY_Alt_L: case XKB_KEY_Alt_R:
        case XKB_KEY_Super_L: case XKB_KEY_Super_R:
        case XKB_KEY_Hyper_L: case XKB_KEY_Hyper_R:
          return 1;
        default:
          return 0;
        }
      }

      xkb_keysym_t xkb_state_key_get_one_sym(struct xkb_state *state,
                                             xkb_keycode_t kc)
      {
        static one_sym_fn real;
        if (!real)
          real = (one_sym_fn)dlsym(RTLD_NEXT, "xkb_state_key_get_one_sym");
        if (!real)
          return XKB_KEY_NoSymbol;

        xkb_keysym_t sym = real(state, kc);
        if (!state
            || (sym != XKB_KEY_Caps_Lock && sym != XKB_KEY_Shift_Lock
                && sym != XKB_KEY_Num_Lock))
          return sym;

        /* The state pulled the shifted level in.  If this key is really a
         * modifier, its level-0 symbol is the one the client must see. */
        const struct xkb_keymap *km = xkb_state_get_keymap(state);
        const xkb_keysym_t *syms = 0;
        if (km && xkb_keymap_key_get_syms_by_level(km, kc, 0, 0, &syms) == 1
            && is_modifier(syms[0])) {
          shim_log("keyboard shim: keycode %u 0x%04x -> 0x%04x", kc, sym, syms[0]);
          return syms[0];
        }
        return sym;
      }
      EOF
      $CC -shared -fPIC -O2 -Wall -o libcmcc-kbd.so kbd-shim.c -lxkbcommon
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib"
      cp libcmcc-kbd.so "$out/lib/"
      runHook postInstall
    '';
  };

  # The viewer asks the guest to switch to the *local* window size as soon as a
  # display is created:
  #
  #     spice-widget SPICE displayPrimaryCreate: Display Create W x H 1920 x 1200
  #     now is fullscreen: vm size() 1920x1200 local 3840x2160
  #     spice-widget updateSize: request vm updateDispaly W x H 3840 2160
  #
  # On a HiDPI desktop the Qt app is not scale-aware (it sees the full physical
  # 3840x2160), so the request is 4K.  A cloud PC that cannot drive 4K accepts
  # the mode and ends up black; other clients simply leave the guest at its own
  # resolution and scale on the client side.  It is intermittent because it
  # depends on whether the guest's display driver survives the mode set.
  #
  # Fix: clamp the request to the size the guest already has, i.e. never ask a
  # working guest to grow.  Shrinking (window made smaller) is still allowed.
  # The guest keeps its native resolution and the viewer scales, and the guest
  # resolution can still be changed inside the guest itself.
  #
  # `spice_main_channel_update_display` is a versioned symbol (SPICEGTK_1) in
  # the bundled libspice-client-glib, hence the version script; the helper
  # lookups (session/channels/primary surface) are resolved at run time so the
  # shim has no link-time dependency on the vendor library.  If anything is
  # missing it simply passes the call through unchanged.
  # CMCC_NO_DISPLAY_FIX=1 disables it, CMCC_DEBUG_SHIM=1 logs every request.
  displayFix = stdenv.mkDerivation {
    pname = "cmcc-jtydn-display-fix";
    inherit version;

    dontUnpack = true;

    buildPhase = ''
      runHook preBuild
      cat > display-shim.c <<'EOF'
      #define _GNU_SOURCE
      #include <dlfcn.h>
      #include <errno.h>
      #include <stdarg.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <sys/msg.h>
      #include <unistd.h>

      static void shim_log(const char *fmt, ...)
      {
        va_list ap;
        FILE *f;

        if (!getenv("CMCC_DEBUG_SHIM"))
          return;
        f = fopen("/tmp/cmcc-shim.log", "a");
        if (f) {
          va_start(ap, fmt);
          vfprintf(f, fmt, ap);
          va_end(ap);
          fputc('\n', f);
          fclose(f);
        }
        va_start(ap, fmt);
        vfprintf(stderr, fmt, ap);
        va_end(ap);
        fputc('\n', stderr);
      }

      __attribute__((constructor)) static void shim_init(void)
      {
        shim_log("display shim loaded (pid %d)", (int)getpid());
      }

      /* The viewer starts its USB redirection through a System V message queue
       * (MessageQueue::send -> msgsnd) from the GUI thread, inside its
       * display-invalidate handler.  Nothing reads that queue in this package
       * (the .deb runs the redirect helper from a setuid/systemd setup we do
       * not install), and kernel.msgmnb is only 16 KiB, so a full queue makes
       * msgsnd BLOCK: the GUI thread freezes, no first frame is painted (black
       * window, dead menu) while the decode thread keeps running.
       *
       * Never block there: send with IPC_NOWAIT and, when the queue is full or
       * gone, drop the message and report success. */
      int msgsnd_impl(int msqid, const void *msgp, size_t msgsz, int msgflg)
      {
        static int (*real_msgsnd)(int, const void *, size_t, int);

        if (!real_msgsnd)
          real_msgsnd = (int (*)(int, const void *, size_t, int))
                        dlsym(RTLD_NEXT, "msgsnd");
        if (!real_msgsnd) {
          errno = ENOSYS;
          return -1;
        }

        if (real_msgsnd(msqid, msgp, msgsz, msgflg | IPC_NOWAIT) == 0)
          return 0;
        if (errno == EAGAIN || errno == EIDRM) {
          shim_log("display shim: msgsnd queue %d full/gone (%s), dropped",
                   msqid, errno == EAGAIN ? "EAGAIN" : "EIDRM");
          return 0;
        }
        return -1;
      }
      __asm__(".symver msgsnd_impl,msgsnd@@GLIBC_2.2.5");

      typedef struct _ShimGList {
        void *data;
        struct _ShimGList *next;
        struct _ShimGList *prev;
      } ShimGList;

      typedef void (*update_fn)(void *, int, int, int, int, int, int);
      typedef void *(*get_session_fn)(void *);
      typedef ShimGList *(*get_channels_fn)(void *);
      typedef int (*is_a_fn)(void *, unsigned long);
      typedef unsigned long (*get_type_fn)(void);
      typedef void (*get_primary_fn)(void *, unsigned int *, unsigned int *,
                                     unsigned int *);

      static update_fn real_update;
      static get_session_fn get_session;
      static get_channels_fn get_channels;
      static is_a_fn is_a;
      static get_type_fn display_type;
      static get_primary_fn get_primary;

      static void resolve(void)
      {
        if (real_update)
          return;
        real_update  = (update_fn)dlsym(RTLD_NEXT, "spice_main_channel_update_display");
        get_session  = (get_session_fn)dlsym(RTLD_DEFAULT, "spice_channel_get_session");
        get_channels = (get_channels_fn)dlsym(RTLD_DEFAULT, "spice_session_get_channels");
        is_a         = (is_a_fn)dlsym(RTLD_DEFAULT, "g_type_check_instance_is_a");
        display_type = (get_type_fn)dlsym(RTLD_DEFAULT, "spice_display_channel_get_type");
        get_primary  = (get_primary_fn)dlsym(RTLD_DEFAULT,
                                             "spice_display_channel_get_primary");
      }

      /* Optional hard cap from the launcher: CMCC_MAX_DISPLAY=WxH. */
      static void max_size(int *w, int *h)
      {
        const char *s = getenv("CMCC_MAX_DISPLAY");
        *w = 0;
        *h = 0;
        if (s && sscanf(s, "%dx%d", w, h) != 2) {
          *w = 0;
          *h = 0;
        }
      }

      /* Current guest primary surface, 0x0 when it has not been created yet. */
      static void guest_size(void *channel, unsigned int *w, unsigned int *h)
      {
        *w = 0;
        *h = 0;
        if (!get_session || !get_channels || !is_a || !display_type || !get_primary)
          return;
        void *session = get_session(channel);
        if (!session)
          return;
        for (ShimGList *l = get_channels(session); l; l = l->next) {
          if (!l->data || !is_a(l->data, display_type()))
            continue;
          unsigned int sid = 0, dw = 0, dh = 0;
          get_primary(l->data, &sid, &dw, &dh);
          if (dw && dh) {
            *w = dw;
            *h = dh;
            return;
          }
        }
      }

      void spice_main_channel_update_display(void *channel, int id, int x, int y,
                                             int w, int h, int display)
      {
        int rw = w, rh = h;

        resolve();
        shim_log("display shim: call %dx%d", rw, rh);
        if (!channel || !real_update)
          return;

        if (w > 0 && h > 0) {
          int mw = 0, mh = 0;
          max_size(&mw, &mh);
          if (mw > 0 && w > mw)
            w = mw;
          if (mh > 0 && h > mh)
            h = mh;

          unsigned int gw = 0, gh = 0;
          guest_size(channel, &gw, &gh);
          if (gw && gh) {
            if (w > (int)gw)
              w = (int)gw;
            if (h > (int)gh)
              h = (int)gh;
          }
          shim_log("display shim: request %dx%d, max %dx%d, guest %ux%u -> sent %dx%d",
                   rw, rh, mw, mh, gw, gh, w, h);
        }
        real_update(channel, id, x, y, w, h, display);
      }
      EOF
      cat > SPICEGTK_1.map <<'EOF'
      GLIBC_2.2.5 {
        global: msgsnd;
      };
      SPICEGTK_1 {
        global: spice_main_channel_update_display;
        local: *;
      };
      EOF
      $CC -shared -fPIC -O2 -Wall -Wl,--version-script=SPICEGTK_1.map \
        -o libcmcc-display.so display-shim.c
      runHook postBuild
    '';

    # Make sure the versioned symbol really interposes another SPICEGTK_1
    # provider when this object is preloaded.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      cat > fake.c <<'EOF'
      void spice_main_channel_update_display(void *c, int i, int x, int y,
                                             int w, int h, int d) { }
      EOF
      cat > main.c <<'EOF'
      void spice_main_channel_update_display(void *, int, int, int, int, int, int);
      int main(void)
      {
        /* a non-null dummy channel: the real function is the fake below, and
         * the spice helper lookups resolve to nothing, so only the cap runs */
        spice_main_channel_update_display((void *)1, 0, 0, 0, 3840, 2160, 1);
        return 0;
      }
      EOF
      $CC -shared -fPIC -Wl,--version-script=SPICEGTK_1.map -o libfake.so fake.c
      $CC -Wall -o probe main.c -L. -lfake -Wl,-rpath,"$PWD"
      probe_out=$(LD_PRELOAD="$PWD/libcmcc-display.so" LD_LIBRARY_PATH="$PWD" \
                  CMCC_DEBUG_SHIM=1 CMCC_MAX_DISPLAY=1920x1080 ./probe 2>&1)
      echo "$probe_out"
      echo "$probe_out" | grep -q 'display shim: call 3840x2160'
      echo "$probe_out" | grep -q 'sent 1920x1080'

      # msgsnd on a full queue must return instead of sleeping forever
      cat > msgtest.c <<'EOF'
      #include <stdio.h>
      #include <string.h>
      #include <sys/msg.h>
      #include <unistd.h>

      struct mb { long mtype; char data[2048]; };

      int main(void)
      {
        struct mb m;
        struct msqid_ds ds;
        int q, i, n = 0, rc;

        alarm(15);
        q = msgget(IPC_PRIVATE, 0666 | IPC_CREAT);
        if (q < 0) { perror("msgget"); return 2; }
        memset(&m, 0, sizeof m);
        m.mtype = 1;

        /* fill the queue: do not use msgsnd's return value for the stop
         * condition, the shim turns EAGAIN into success on purpose */
        for (i = 0; i < 64; i++) {
          if (msgctl(q, IPC_STAT, &ds) != 0)
            break;
          if (ds.msg_qbytes - ds.msg_cbytes < sizeof m.data)
            break;
          if (msgsnd(q, &m, sizeof m.data, IPC_NOWAIT) != 0)
            break;
          n++;
        }
        printf("queue filled with %d messages\n", n);

        rc = msgsnd(q, &m, sizeof m.data, 0);   /* would block without the shim */
        printf("full-queue msgsnd rc=%d\n", rc);
        msgctl(q, IPC_RMID, 0);
        return (n > 0 && rc == 0) ? 0 : 1;
      }
      EOF
      $CC -Wall -o msgprobe msgtest.c
      msg_out=$(LD_PRELOAD="$PWD/libcmcc-display.so" LD_LIBRARY_PATH="$PWD" \
                CMCC_DEBUG_SHIM=1 ./msgprobe 2>&1)
      echo "$msg_out"
      echo "$msg_out" | grep -q 'full-queue msgsnd rc=0'
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib"
      cp libcmcc-display.so "$out/lib/"
      runHook postInstall
    '';
  };
}
