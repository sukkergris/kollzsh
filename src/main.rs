mod extract;
mod ollama;
mod llamacpp;
mod vllm;
mod logging;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "kollzsh")]
#[command(about = "AI-powered shell command suggestions")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Use Ollama API (also supports OpenAI/DeepSeek compatible APIs)
    Ollama {
        /// The query to generate commands for
        query: Vec<String>,
    },
    /// Use llama.cpp (server or CLI mode)
    Llamacpp {
        /// The query to generate commands for
        query: Vec<String>,
    },
    /// Use vLLM server
    Vllm {
        /// The query to generate commands for
        query: Vec<String>,
    },
}

fn main() -> Result<()> {
    logging::init_logging();

    let cli = Cli::parse();

    let commands = match cli.command {
        Commands::Ollama { query } => {
            let query_str = query.join(" ");
            ollama::interact(&query_str)?
        }
        Commands::Llamacpp { query } => {
            let query_str = query.join(" ");
            llamacpp::interact(&query_str)?
        }
        Commands::Vllm { query } => {
            let query_str = query.join(" ");
            vllm::interact(&query_str)?
        }
    };

    if commands.is_empty() {
        log::debug!("No valid commands found");
        std::process::exit(1);
    }

    for cmd in commands {
        println!("{}", cmd);
    }

    log::debug!("Successfully output commands");
    Ok(())
}
