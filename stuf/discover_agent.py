import os
import subprocess
import json


def find_java_pid():
    """Automatically find the PID of a Java process listening on a TCP6 port."""
    try:
        result = subprocess.run(["netstat", "-tulnp"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                universal_newlines=True)
        for line in result.stdout.splitlines():
            if "java" in line and "tcp6" in line and "LISTEN" in line:
                parts = line.split()
                pid_process = parts[-1]  # Example: "1234/java"
                pid = pid_process.split("/")[0]
                return pid
    except Exception as e:
        print(f"Error finding Java process: {e}")
    return None


def find_agent_home(pid):
    """Find the Oracle agent home by reading /proc/{pid}/cwd."""
    cwd_path = f"/proc/{pid}/cwd"
    try:
        if os.path.islink(cwd_path):
            real_path = os.readlink(cwd_path)
            if real_path.endswith("/sysman/emd"):
                agent_home = real_path[:-len("/sysman/emd")]
                return agent_home
    except Exception as e:
        print(f"Error accessing {cwd_path}: {e}")
    return None


def get_agent_info(agent_home):
    """Run 'emctl status agent' and extract agent binaries path and version."""
    emctl_path = os.path.join(agent_home, "bin", "emctl")
    agent_info = {
        "agent_home": agent_home,
        "agent_binaries": None,
        "agent_version": None
    }

    try:
        if os.path.exists(emctl_path):
            result = subprocess.run([emctl_path, "status", "agent"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    universal_newlines=True)
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if "Oracle Home" in line:
                        agent_info["agent_binaries"] = line.split(":")[-1].strip()
                    elif "Agent Version" in line:
                        agent_info["agent_version"] = line.split(":")[-1].strip()
        else:
            print(f"{emctl_path} not found.")
    except Exception as e:
        print(f"Error running emctl status agent: {e}")

    return agent_info


def main():
    pid = find_java_pid()
    if pid:
        agent_home = find_agent_home(pid)
        if agent_home:
            agent_info = get_agent_info(agent_home)
            print(json.dumps(agent_info, indent=4))
        else:
            print(json.dumps({"error": "Agent home could not be found"}, indent=4))
    else:
        print(json.dumps({"error": "No suitable Java process found"}, indent=4))


if __name__ == "__main__":
    main()