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

## Network Configuration
By default, the standalone server hosts a standard Godot ENet LAN server on port **12345**.

If your team is connecting over the internet, you must ensure that **Port 12345 (UDP)** is forwarded on your router to the machine running the server.

Once the server is running, players can join by entering your machine's IP address into the **LAN Connection** box in their Godot editor and clicking **Join**.
