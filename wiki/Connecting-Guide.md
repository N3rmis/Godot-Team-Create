# Connecting Guide

Here are the ways to connect to each other. Pick whatever is easiest for you.

## 1. LAN (Same Wi-Fi)

If you're on the same local network:

### Host:
1. Open the Team Create dock.
2. Pick a username and click **Host LAN**.
3. Open cmd, type `ipconfig`, and find your IPv4 address (like `192.168.1.something`). Give that to your friend.

### Joiner:
1. Open the Team Create dock.
2. Type the host's local IP into the box.
3. Click **Join**.

## 2. Radmin VPN or Hamachi (Recommended if you don't wanna port forward)

If you aren't on the same Wi-Fi and don't want to mess with your router settings, just use Radmin VPN or Hamachi. It's completely free and legal. It basically tricks your computers into thinking you're on LAN.

1. Both of you download and install Radmin VPN (or Hamachi).
2. Host makes a network with a name and password.
3. Friend joins that network.
4. Friend copies the host's IP from Radmin/Hamachi (it usually starts with `26.` or `25.`).
5. Paste that IP into the Team Create dock and click **Join**.

## 3. Port Forwarding (Direct Internet)

If you know how to port forward:

1. In your router settings, forward port **25567** (both **UDP** and **TCP**) to your PC's local IP.
2. Make sure Windows Firewall isn't blocking Godot.
3. Click **Host LAN** in the dock.
4. Give your friend your public IP address (google "what is my ip").
5. Friend puts your public IP in the dock and clicks **Join**.

## 4. Headless Dedicated Server

If you want a server running 24/7 without keeping the Godot editor open on your PC:

1. Open the Team Create dock.
2. Scroll to the bottom and click **Export Headless Server**.
3. Pick an empty folder and save it.
4. In that folder, run:
   - **Windows:** `start_server.bat`
   - **Linux:** `./start_server.sh`
5. Connect to it by putting the server machine's IP or domain into the dock and clicking **Join**.

If the server is on the internet, **set a password**. See [the server guide](../README_SERVER.md#setting-a-password) for how to set one and use a domain.

## Project Settings

Project settings sync automatically while you're connected, so there's no need to share `project.godot`. See [the server guide](../README_SERVER.md#project-settings) for how autoloads behave on a dedicated server.

## Passwords

Type a password into the **Server Password** box before clicking **Host LAN** or **Join**. When hosting, that becomes the session password, and it isn't saved.

To avoid typing it each time you join, tick **Remember Password**. Once the server accepts it, the editor saves a hash of the password on your computer and joins that server by itself whenever you open this project. Joining makes your project folder match the server, so this also happens without a click. Untick the box to forget the password. If the password changes, the saved one is forgotten and you'll be asked to type the new one.

Anyone who copies that saved file can join the server until the password is changed, and could try to guess a short password from it, so use a long random password.

## Encryption

Connections are encrypted automatically, so there's nothing to set up. The password also proves you've reached the real server, so use one whenever you connect over the internet. Everyone needs the exact same copy of the plugin, and the server refuses to let you join if yours is different. If the server has a password, it offers you its copy, and you can update and restart with one click.
