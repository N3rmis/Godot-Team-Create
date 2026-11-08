# Team Create Standalone Headless Server

You can host a Team Create session without keeping your Godot Editor open by exporting a standalone headless server directly from the plugin.

## How to Export the Server

1. Open your project in the Godot Editor.
2. Open the **Team Create** dock panel.
3. Scroll to the bottom and click the **Export Headless Server** button.
4. Choose an empty output directory on your computer to save the server files.

## How to Run the Server

Once exported, navigate to the folder you selected.

You will see a `project/` folder along with `.bat` and `.sh` scripts. These scripts use your existing Godot engine to host the server.
- **Windows:** Double click `start_server.bat`
- **Linux:** Run `./start_server.sh` from your terminal.

*(Note: The wrapper scripts automatically look for a Godot executable in the same directory, or fallback to the system `godot` command in your PATH. If it fails to launch, you can manually place a copy of your Godot engine executable in the folder or update the script to point directly to it.)*

## Setting a Password

**Always set a password on a server that's reachable from the internet.** Without one, anyone who finds it can join and change your project.

Set the `TEAM_CREATE_PASSWORD` environment variable before starting the server:

- **Linux:** `read -rs TEAM_CREATE_PASSWORD && export TEAM_CREATE_PASSWORD && ./start_server.sh` (type the password, then press Enter)
- **Windows:** run `set TEAM_CREATE_PASSWORD=your-password` in a Command Prompt, then run `start_server.bat` from the same window.

Players type the same password into the **Server Password** box before clicking **Join**, and can tick **Remember Password** to save it and join by itself when that project opens. Everyone must have the exact same copy of the plugin, and the server refuses to let anyone with a different copy join.

**To update everyone, update the plugin on the server.** On a server with a password, anyone joining with a different copy is offered the server's copy once their password is accepted. If they accept, it's checked, installed, and the editor restarts. This installs code from the server onto their machine, which is another reason to only share the password with people you fully trust. Copies from before this feature can't update themselves, and on a server with no password people have to install the new copy by hand.

Use a long random password. After 5 wrong attempts, an address is blocked for 5 minutes.

Traffic is always encrypted, using a certificate the server generates when it starts, so there's nothing to set up. The password is what proves you've reached the real server, so a server with no password is encrypted but its identity can't be checked.

The password keeps strangers out, but anyone who has it can still change project files and run code on the server through a scene's scripts, so only share it with people you fully trust.

## Deploy to Website

A dedicated server can give everyone in the session a **Deploy to Website** button that publishes the project's current saved state, for example to a site hosting your web export. Without this setup, the button doesn't appear.

The plugin only passes the request along. [`tools/site_deploy.sh`](tools/site_deploy.sh) does the work, running on the server machine but outside any container, so the server itself never needs network access or upload credentials. It copies the project, leaves out the Team Create plugin, exports it and uploads the result with `rsync`. If the export fails or produces nothing, the site isn't changed.

1. Create `deploy.env` in the base folder (`/srv/team-create` by default, or set `DEPLOY_BASE`), with `SITE=user@host:/var/www/mygame/`. The comments at the top of the script list the other settings.
2. Create `deploy/request`, writable by the server's user, and `deploy/status`, writable by the user running the script and readable by the server.
3. Keep `tools/site_deploy.sh` running, with Godot and its export templates installed for that user.
4. Start the server with `TEAM_CREATE_DEPLOY_DIR` set to the folder containing `request` and `status`.

Anyone who has the server password can press the button, and it replaces the live site for everyone playing.


## Project Settings

Project settings sync between everyone in a session as they're changed, including the input map, layers, display and rendering settings, the main scene, and autoloads. A player joining is matched to the server's settings. Which editor plugins are enabled isn't synced, but a plugin's files only stay if they're on the server too.

**Joining makes your project folder match the server.** Local scripts and scenes the server doesn't have are moved to `.team_create/trash`, and any other files it doesn't have are deleted. Commit or back up your work before joining, or join from a separate folder.

Some settings only fully apply after restarting the editor, and players get a reminder when that's the case.

A running server can't take on new autoloads, because scripts that use them won't compile until it restarts. It posts a notice in chat and restarts by itself once everyone has left. Until then, scenes that use a new autoload can't be saved on the server, and chat says which ones. If the server runs in a container, it needs a restart policy so that it comes back up.

An autoload runs on the server and on everyone's machine when the game runs, which is part of why the password should only go to people you fully trust.

## Using a Domain

1. Add a DNS `A` record pointing your domain (e.g. `play.example.com`) at the server's public IP. Use a dynamic DNS service if that IP changes.
2. Open **Port 25567 (both UDP and TCP)** on the server. Players can enter `play.example.com` or `play.example.com:25567` in the join box.
3. Keep the record **DNS only**. Don't use a proxy or tunnel such as the Cloudflare orange cloud, ngrok, or playit: they won't carry this traffic properly, and the server treats anyone connecting from `127.0.0.1` as an admin.

## Network Configuration
By default, the standalone server hosts both multiplayer synchronization (ENet with DTLS / UDP) and asset streaming (HTTPS / TCP) on the same port: **25567**. You can also change the port at runtime in the server console with `/port <number>`.

If your team is connecting over the internet, you must ensure that **Port 25567 (both UDP and TCP)** is open/forwarded on your firewall or router.

Once the server is running, players can join by entering your machine's IP address (e.g. `IP` or `IP:25567`) into the **LAN Connection** box in their Godot editor and clicking **Join**.
