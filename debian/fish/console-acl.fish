# run console-vt.py for /dev/tty$XDG_VTNR in a login shell
if status is-login; and set -q XDG_VTNR; and test -x /usr/lib/rhizo/install/bootstrap/console-vt.py
    if string match -qr '^[0-9]+$' -- $XDG_VTNR
        /usr/lib/rhizo/install/bootstrap/console-vt.py /dev/tty$XDG_VTNR
    end
end
