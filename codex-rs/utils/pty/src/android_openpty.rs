use libc::c_char;
use libc::c_int;
use libc::termios;
use libc::winsize;

/// Android's Bionic libc does not export `openpty`, which `portable-pty`
/// expects on Unix targets. Provide the standard operation using the POSIX PTY
/// primitives Bionic does expose.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn openpty(
    master_out: *mut c_int,
    slave_out: *mut c_int,
    name_out: *mut c_char,
    termios: *const termios,
    winsize: *const winsize,
) -> c_int {
    if master_out.is_null() || slave_out.is_null() {
        return -1;
    }

    let master = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) };
    if master < 0 {
        return -1;
    }

    if unsafe { libc::grantpt(master) } != 0 || unsafe { libc::unlockpt(master) } != 0 {
        unsafe { libc::close(master) };
        return -1;
    }

    let mut name = [0 as c_char; 128];
    if unsafe { libc::ptsname_r(master, name.as_mut_ptr(), name.len()) } != 0 {
        unsafe { libc::close(master) };
        return -1;
    }

    let slave = unsafe { libc::open(name.as_ptr(), libc::O_RDWR | libc::O_NOCTTY) };
    if slave < 0 {
        unsafe { libc::close(master) };
        return -1;
    }

    if !termios.is_null() && unsafe { libc::tcsetattr(slave, libc::TCSAFLUSH, termios) } != 0 {
        unsafe {
            libc::close(slave);
            libc::close(master);
        }
        return -1;
    }
    if !winsize.is_null() && unsafe { libc::ioctl(slave, libc::TIOCSWINSZ, winsize) } != 0 {
        unsafe {
            libc::close(slave);
            libc::close(master);
        }
        return -1;
    }
    if !name_out.is_null() {
        unsafe { libc::strcpy(name_out, name.as_ptr()) };
    }

    unsafe {
        *master_out = master;
        *slave_out = slave;
    }
    0
}
