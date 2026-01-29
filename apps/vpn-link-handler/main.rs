// File: apps/vpn-link-handler/main.rs
use anyhow::{Context, Result};
use directories::ProjectDirs;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::net::UdpSocket;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

// Constants
const UDP_PORT: u16 = 32800;
const DISCOVERY_MSG: &str = "GP_DISCOVER";
const PROTOCOL_SCHEME: &str = "globalprotect";
const APP_NAME: &str = "VPN Link Handler";
const BINARY_NAME: &str = "vpn-link-handler";
const CONFIG_FILE_NAME: &str = "proxy_url.txt";

fn main() -> Result<()> {
    env_logger::init();
    let args: Vec<String> = env::args().collect();

    // MODE 1: HANDLING LINKS (Silent)
    // Triggered by browser: vpn-link-handler globalprotect://...
    if args.len() > 1 && args[1].starts_with("globalprotect://") {
        match handle_link(&args[1]) {
            Ok(_) => return Ok(()),
            Err(e) => {
                // Log error to stderr (might be captured by OS logs)
                eprintln!("Error handling link: {:#}", e);
                std::process::exit(1);
            }
        }
    }

    // MODE 2: UNINSTALLATION (Explicit)
    if args.len() > 1 && args[1] == "--uninstall" {
        uninstall_process()?;
        return Ok(());
    }

    // MODE 3: INTERACTIVE SETUP (Default)
    interactive_setup()?;
    Ok(())
}

fn handle_link(url: &str) -> Result<()> {
    let proxy_base =
        load_config().context("Configuration missing. Please run the tool manually to setup.")?;
    let target_endpoint = format!("{}/submit", proxy_base.trim_end_matches('/'));
    forward_to_container(&target_endpoint, url)?;
    Ok(())
}

// --- SETUP & REMOVAL UI ---

fn interactive_setup() -> Result<()> {
    println!("========================================");
    println!("   {} Setup", APP_NAME);
    println!("========================================");

    // 1. Suggest location check
    if let Ok(exe) = env::current_exe() {
        let exe_lossy = exe.to_string_lossy();
        if exe_lossy.contains("Downloads") || exe_lossy.contains("Temp") {
            println!("\nWARNING: You are running this from a temporary folder.");
            println!("If you move this file later, the integration will break.");
            println!("Recommendation: Move it to 'Documents' or 'Applications' first.\n");
        }
    }

    // 2. Check existing config
    if let Ok(current) = load_config() {
        println!("Status: Configured");
        println!("Target: {}", current);
        println!("");
        println!("Options:");
        println!("  [1] Re-configure");
        println!("  [2] Uninstall / Remove");
        println!("  [Enter] Exit");
        print!("> ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        match input.trim() {
            "1" => {} // Continue to setup
            "2" => {
                uninstall_process()?;
                return Ok(());
            }
            _ => return Ok(()),
        }
    }

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
            println!("No proxy found automatically (UDP broadcast silent).");
        }
    }

    // 4. Prompt for URL
    println!("");
    if !discovered_url.is_empty() {
        println!(
            "Press Enter to use [{}], or type a new URL.",
            discovered_url
        );
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

    // 5. Save & Install
    println!("");
    println!("Saving configuration...");
    save_config(&final_url)?;

    println!("Registering with Operating System...");
    if let Err(e) = install_handler() {
        println!("ERROR: Failed to register handler.");
        println!("Details: {:#}", e);
    } else {
        println!("SUCCESS! The handler is registered.");
        println!("You can now click 'SSO Login' links in your browser.");
    }

    println!("");
    wait_for_enter();
    Ok(())
}

fn uninstall_process() -> Result<()> {
    println!("");
    println!("Removing {}...", APP_NAME);

    // 1. Remove OS Integration
    match uninstall_handler() {
        Ok(_) => println!(" - OS Registry/Shortcuts removed."),
        Err(e) => println!(" - Warning: OS cleanup failed: {}", e),
    }

    // 2. Remove Config
    match remove_config() {
        Ok(_) => println!(" - Configuration file removed."),
        Err(e) => println!(" - Warning: Config cleanup failed: {}", e),
    }

    println!("");
    println!("Uninstallation Complete.");
    println!("You may now delete this executable file.");
    wait_for_enter();
    Ok(())
}

fn wait_for_enter() {
    print!("Press Enter to close...");
    io::stdout().flush().unwrap();
    let _ = io::stdin().read_line(&mut String::new());
}

// --- DISCOVERY ---

fn try_discover() -> Result<String> {
    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.set_broadcast(true)?;
    socket.set_read_timeout(Some(Duration::from_millis(1500)))?;

    // Send Broadcast
    socket.send_to(
        DISCOVERY_MSG.as_bytes(),
        format!("255.255.255.255:{}", UDP_PORT),
    )?;

    // Listen for Reply
    let mut buf = [0; 1024];
    let (amt, _src) = socket.recv_from(&mut buf)?;

    // Parse JSON manually to avoid dependencies
    let response = String::from_utf8_lossy(&buf[..amt]);

    // Simple parsing: Look for "ip": "1.2.3.4"
    if let Some(start) = response.find("\"ip\": \"") {
        let rest = &response[start + 7..];
        if let Some(end) = rest.find("\"") {
            let ip = &rest[..end];
            return Ok(ip.to_string());
        }
    }

    anyhow::bail!("Invalid response format");
}

// --- CONFIGURATION MANAGEMENT ---

fn get_config_path() -> Result<PathBuf> {
    let proj_dirs = ProjectDirs::from("com", "gpproxy", "linkhandler")
        .context("Could not determine config directory")?;
    let config_dir = proj_dirs.config_dir();
    if !config_dir.exists() {
        fs::create_dir_all(config_dir)?;
    }
    Ok(config_dir.join(CONFIG_FILE_NAME))
}

fn save_config(url: &str) -> Result<()> {
    let path = get_config_path()?;
    fs::write(&path, url)?;
    Ok(())
}

fn load_config() -> Result<String> {
    let path = get_config_path()?;
    if !path.exists() {
        anyhow::bail!("Config not found");
    }
    let url = fs::read_to_string(path)?;
    Ok(url.trim().to_string())
}

fn remove_config() -> Result<()> {
    let path = get_config_path()?;
    if path.exists() {
        fs::remove_file(&path)?;
        // Try to remove the parent directory if empty
        if let Some(parent) = path.parent() {
            let _ = fs::remove_dir(parent);
        }
    }
    Ok(())
}

// --- NETWORK ---

fn forward_to_container(endpoint: &str, callback_url: &str) -> Result<()> {
    println!("Forwarding to: {}", endpoint);

    let resp = ureq::post(endpoint)
        .set("Content-Type", "application/x-www-form-urlencoded")
        .send_form(&[("callback_url", callback_url)])?;

    if resp.status() != 200 {
        anyhow::bail!("Server returned error: {}", resp.status());
    }
    println!("Success! VPN Connection Initiated.");
    Ok(())
}

// =============================================================================
// WINDOWS IMPLEMENTATION
// =============================================================================
#[cfg(target_os = "windows")]
fn install_handler() -> Result<()> {
    use winreg::enums::*;
    use winreg::RegKey;

    let exe_path = env::current_exe()?;
    let exe_path_str = exe_path.to_str().unwrap();

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let path = std::path::Path::new("Software")
        .join("Classes")
        .join(PROTOCOL_SCHEME);

    let (key, _) = hkcu.create_subkey(&path)?;
    key.set_value("", &format!("URL:{} Protocol", APP_NAME))?;
    key.set_value("URL Protocol", &"")?;

    let cmd_key = key.create_subkey("shell\\open\\command")?.0;
    // Quote the executable path to handle spaces
    let cmd_val = format!("\"{}\" \"%1\"", exe_path_str);
    cmd_key.set_value("", &cmd_val)?;

    Ok(())
}

#[cfg(target_os = "windows")]
fn uninstall_handler() -> Result<()> {
    use winreg::enums::*;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let path = std::path::Path::new("Software")
        .join("Classes")
        .join(PROTOCOL_SCHEME);

    // delete_subkey_all is recursive
    hkcu.delete_subkey_all(&path)
        .context("Failed to delete Registry key")?;
    Ok(())
}

// =============================================================================
// LINUX IMPLEMENTATION
// =============================================================================
#[cfg(target_os = "linux")]
fn install_handler() -> Result<()> {
    let exe_path = env::current_exe()?;
    let desktop_file_content = format!(
        "[Desktop Entry]\n\
        Type=Application\n\
        Name={}\n\
        Exec={} %u\n\
        StartupNotify=false\n\
        MimeType=x-scheme-handler/{};\n",
        APP_NAME,
        exe_path.to_string_lossy(),
        PROTOCOL_SCHEME
    );

    let dirs = directories::BaseDirs::new().context("No home dir")?;
    let apps_dir = dirs.data_local_dir().join("applications");

    if !apps_dir.exists() {
        fs::create_dir_all(&apps_dir)?;
    }

    let file_path = apps_dir.join(format!("{}.desktop", BINARY_NAME));
    fs::write(&file_path, desktop_file_content)?;

    Command::new("xdg-mime")
        .args(&[
            "default",
            format!("{}.desktop", BINARY_NAME).as_str(),
            &format!("x-scheme-handler/{}", PROTOCOL_SCHEME),
        ])
        .status()?;

    Ok(())
}

#[cfg(target_os = "linux")]
fn uninstall_handler() -> Result<()> {
    let dirs = directories::BaseDirs::new().context("No home dir")?;
    let apps_dir = dirs.data_local_dir().join("applications");
    let file_path = apps_dir.join(format!("{}.desktop", BINARY_NAME));

    if file_path.exists() {
        fs::remove_file(&file_path)?;
    }

    let _ = Command::new("update-desktop-database")
        .arg(&apps_dir)
        .status();
    Ok(())
}

// =============================================================================
// MACOS IMPLEMENTATION
// =============================================================================
#[cfg(target_os = "macos")]
fn install_handler() -> Result<()> {
    let exe_path = env::current_exe()?;
    let dirs = directories::UserDirs::new().context("No home dir")?;
    let app_path = dirs
        .home_dir()
        .join(format!("Applications/{}.app", APP_NAME));

    let macos_dir = app_path.join("Contents/MacOS");
    fs::create_dir_all(&macos_dir)?;

    let dest_exe = macos_dir.join(BINARY_NAME);
    fs::copy(&exe_path, &dest_exe)?;

    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>{}</string>
    <key>CFBundleIdentifier</key>
    <string>com.gpproxy.linkhandler</string>
    <key>CFBundleName</key>
    <string>{}</string>
    <key>CFBundleDisplayName</key>
    <string>{}</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>VPN Login Link</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>globalprotect</string>
            </array>
        </dict>
    </array>
</dict>
</plist>"#,
        BINARY_NAME, APP_NAME, APP_NAME
    );

    fs::write(app_path.join("Contents/Info.plist"), plist)?;

    Command::new(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    )
    .arg("-f")
    .arg(&app_path)
    .status()
    .ok();

    Ok(())
}

#[cfg(target_os = "macos")]
fn uninstall_handler() -> Result<()> {
    let dirs = directories::UserDirs::new().context("No home dir")?;
    let app_path = dirs
        .home_dir()
        .join(format!("Applications/{}.app", APP_NAME));

    if app_path.exists() {
        fs::remove_dir_all(&app_path)?;
    }

    Command::new(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    )
    .arg("-f")
    .arg(&app_path) // Pointing to deleted path forces cleanup in LS database
    .status()
    .ok();

    Ok(())
}
