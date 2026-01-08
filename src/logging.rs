use log::LevelFilter;
use simplelog::{Config, WriteLogger};
use std::fs::OpenOptions;

const LOG_FILE: &str = "/tmp/kollzsh_debug.log";

pub fn init_logging() {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(LOG_FILE)
        .unwrap_or_else(|_| {
            // Fallback to /dev/null if we can't open log file
            OpenOptions::new()
                .write(true)
                .open("/dev/null")
                .unwrap()
        });

    let _ = WriteLogger::init(LevelFilter::Debug, Config::default(), file);
}
