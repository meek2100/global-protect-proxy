use anyhow::{Context, Result};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::net::UdpSocket;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use directories::ProjectDirs;

// Constants
const UDP_PORT: u16 = 32800;
const DISCOVERY_MSG: &str = "GP_DISCOVER";
// ... [Other constants remain same] ...

// ... [main function remains same] ...

// ... [handle_link function remains same] ...

fn interactive_setup() -> Result<()> {
    println!("========================================");
    println!("   {} Setup", APP_NAME);
    println!("========================================");

    // 1. Suggest location check
    if let Ok(exe) = env::current_exe() {
        if exe.to_string_lossy().contains("Downloads") {
            println!("\nWARNING: You are running this from the Downloads folder.");
            println!("If you move this file later, the integration will break.");
            println!("Recommendation: Move it to 'Documents' or 'Applications' first.\n");
        }
    }

    // 2. Check existing config
    // ... [Same logic as before] ...

    // 3. AUTO-DISCOVERY
    println!("");
    println!("Scanning network for GP Proxy...");

    let mut discovered_url = String::new();

    match try_discover() {
        Ok(ip) => {
            println!("FOUND: GP Proxy at {}", ip);
            discovered_url = format!("http://{}:8001", ip);
        }
        Err(_) => {
            println!("No proxy found automatically.");
        }
    }

    // 4. Prompt for URL (Pre-filled if found)
    println!("");
    if !discovered_url.is_empty() {
        println!("Press Enter to use [{}], or type a new URL.", discovered_url);
    } else {
        println!("Please enter the URL of your GP Proxy.");
        println!("Example: http://192.168.1.155:8001");
    }

    print!("> ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    let input = input.trim();

    let final_url = if input.is_empty() && !discovered_url.is_empty() {
        discovered_url
    } else {
        input.to_string()
    };

    if final_url.is_empty() {
        println!("Error: URL cannot be empty.");
        wait_for_enter();
        return Ok(());
    }

    // ... [Save & Install Logic remains same] ...
    // ...
}

// --- NEW DISCOVERY FUNCTION ---
fn try_discover() -> Result<String> {
    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.set_broadcast(true)?;
    socket.set_read_timeout(Some(Duration::from_millis(1500)))?;

    // Send Broadcast
    socket.send_to(DISCOVERY_MSG.as_bytes(), format!("255.255.255.255:{}", UDP_PORT))?;

    // Listen for Reply
    let mut buf = [0; 1024];
    let (amt, _src) = socket.recv_from(&mut buf)?;

    // Parse JSON manually to avoid dependencies, or just assume format
    let response = String::from_utf8_lossy(&buf[..amt]);

    // Simple parsing: {"ip": "1.2.3.4", ...}
    // We scan for the IP value to keep binary small (no serde_json dependency needed yet)
    if let Some(start) = response.find("\"ip\": \"") {
        let rest = &response[start + 7..];
        if let Some(end) = rest.find("\"") {
            let ip = &rest[..end];
            return Ok(ip.to_string());
        }
    }

    anyhow::bail!("Invalid response format");
}

// ... [Rest of file remains same] ...