# add root to this console's access list at a console login
if status is-login; and set -q XDG_VTNR; and test -x /usr/lib/rhizo/install/bootstrap/console-vt.py
    if string match -qr '^[0-9]+$' -- $XDG_VTNR
        /usr/lib/rhizo/install/bootstrap/console-vt.py /dev/tty$XDG_VTNR
    end
end
