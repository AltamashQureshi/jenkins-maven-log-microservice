# Jenkins Maven Log Microservice

An automated CI/CD pipeline that uses **Jenkins** (running inside Docker) to build and deploy a **Java Maven log-generator microservice** to a remote Kubernetes worker node via SSH — with zero manual intervention after initial setup.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
  - [Jenkins Server](#jenkins-server)
  - [Worker Node (node01)](#worker-node-node01)
- [Repository Structure](#repository-structure)
- [Setup & Installation](#setup--installation)
- [Jenkins Pipeline Configuration](#jenkins-pipeline-configuration)
  - [Pre-Build Step](#pre-build-step)
  - [Post-Build Step](#post-build-step)
- [How It Works](#how-it-works)
- [Log Output Format](#log-output-format)
- [Troubleshooting](#troubleshooting)

---

## Overview

This project automates the following workflow:

1. Jenkins runs inside a **Docker container** on the master server.
2. A shell script (`Final_script.sh`) bootstraps the entire Jenkins setup — pulling the Docker image, configuring SSH keys, and installing dependencies.
3. Jenkins builds a Java `LogGenerator` application using **Maven**.
4. The compiled JAR is transferred via **SSH** to a remote Kubernetes worker node (`node01`).
5. The application is restarted on the worker node and continuously writes structured JSON logs to `/root/app.log`.

---

## Architecture

```
┌─────────────────────────────────┐          ┌──────────────────────────┐
│         Jenkins Server          │          │     Worker Node (node01) │
│                                 │          │                          │
│  ┌──────────────────────────┐   │          │  ┌────────────────────┐  │
│  │  Docker (Jenkins LTS)    │   │  SSH/SCP │  │  log-generator.jar │  │
│  │  - Maven                 │──────────────▶  │  (runs as daemon)  │  │
│  │  - OpenJDK 21            │   │          │  │                    │  │
│  │  - sshpass               │   │          │  │  /root/app.log     │  │
│  └──────────────────────────┘   │          │  └────────────────────┘  │
│                                 │          │                          │
│  Ports: 8080 (UI), 50000 (Agent)│          │  Java + JAVA_HOME set    │
└─────────────────────────────────┘          └──────────────────────────┘
```

---

## Prerequisites

### Jenkins Server

The Jenkins server acts as the CI/CD master. Ensure the following are in place before running the setup script.

#### 1. Required System Packages

Install `dos2unix` to convert Windows-style line endings in the setup script:

```bash
apt install dos2unix
```

Install `sshpass` for automated SSH authentication during initial key exchange:

```bash
apt install sshpass -y
```

#### 2. Required Tools (auto-checked by script)

The `Final_script.sh` script will verify these are present before proceeding:

| Tool       | Purpose                                      |
|------------|----------------------------------------------|
| `docker`   | Runs the Jenkins container                   |
| `kubectl`  | Fetches the worker node IP from Kubernetes   |
| `ssh`      | Remote shell access to node01                |
| `sshpass`  | Non-interactive SSH password authentication  |

#### 3. Convert & Execute the Setup Script

> **Important:** If the script was edited or downloaded on a Windows machine, it **must** be converted to Unix line endings before execution, or it will fail with `bad interpreter` errors.

```bash
# Convert line endings from Windows (CRLF) to Unix (LF)
dos2unix Final_script.sh
```

Expected output:
```
dos2unix: converting file Final_script.sh to Unix format...
```

Then run the script and capture all output to a log file:

```bash
./Final_script.sh 2>&1 | tee -a create.log
```

This will:
- Pull the Jenkins Docker image (`jenkins/jenkins:lts-jdk21`)
- Start the Jenkins container on ports `8080` and `50000`
- Install Maven, OpenJDK 21, and sshpass inside the container
- Generate an SSH key pair inside Jenkins
- Copy the public key to node01 for passwordless SSH
- Print the Jenkins initial admin password on completion

---

### Worker Node (node01)

The worker node is the remote machine where the built JAR will be deployed and run.

#### 1. Java Installation

Java **must** be installed on the worker node since the JAR is executed there directly (not inside Docker).

Install OpenJDK (Java 17 or 21 recommended):

```bash
apt update
apt install -y openjdk-21-jdk
```

#### 2. Configure JAVA_HOME

Set the `JAVA_HOME` environment variable so the application can be run with the full Java path:

```bash
# Find the Java installation path
update-alternatives --config java
# Example output: /usr/lib/jvm/java-21-openjdk-amd64/bin/java

# Set JAVA_HOME permanently
echo 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64' >> /etc/environment
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/environment

# Apply changes to current session
source /etc/environment
```

Verify the setup:

```bash
java -version
echo $JAVA_HOME
```

Expected output:
```
openjdk version "21.x.x" ...
/usr/lib/jvm/java-21-openjdk-amd64
```

> **Note:** The post-build script uses `/usr/bin/java` as the full path. Ensure this symlink exists after installation (`which java` should return `/usr/bin/java`).

#### 3. Root SSH Access

The Jenkins container connects to node01 as `root`. Ensure:
- SSH service is running on node01 (`systemctl status ssh`)
- Root login via SSH is permitted in `/etc/ssh/sshd_config`:
  ```
  PermitRootLogin yes
  ```
- Restart SSH after any config changes: `systemctl restart ssh`

---

## Repository Structure

```
jenkins-maven-log-microservice/
│
├── Final_script.sh              # Main bootstrap script — sets up Jenkins in Docker
├── pre_build-step_script.txt    # Jenkins pre-build shell script (creates Maven project & builds JAR)
├── post_build_script.txt        # Jenkins post-build shell script (deploys & runs JAR on node01)
│
├── proof/
│   └── create.log               # Sample execution log from a successful run
│
├── document/
│   ├── Jenkins Auto_Maven Log Generator Configuration.pdf
│   └── Setup_and_Execute_Proof_Document.docx
│
└── README.md
```

---

## Setup & Installation

### Step 1 — Clone the Repository

```bash
git clone https://github.com/AltamashQureshi/jenkins-maven-log-microservice.git
cd jenkins-maven-log-microservice
```

### Step 2 — Prepare the Worker Node

On `node01`, install Java and configure `JAVA_HOME` as described in the [Worker Node Prerequisites](#worker-node-node01) section.

### Step 3 — Run the Bootstrap Script on the Jenkins Server

```bash
apt install dos2unix
apt install sshpass -y
dos2unix Final_script.sh
./Final_script.sh 2>&1 | tee -a create.log
```

The script will:
1. Detect node01's IP from `kubectl get nodes`
2. Prompt for node01's root password (input is hidden)
3. Test SSH connectivity
4. Pull and start the Jenkins Docker container
5. Install Maven, JDK, and sshpass inside Jenkins
6. Generate SSH keys and push the public key to node01
7. Restart Jenkins and display the admin password

### Step 4 — Access Jenkins UI

Open your browser and navigate to:

```
http://<jenkins-server-ip>:8080
```

Use the **Initial Admin Password** printed at the end of the script output to unlock Jenkins. Install the recommended plugins when prompted.

### Step 5 — Configure the Pipeline

See the [Jenkins Pipeline Configuration](#jenkins-pipeline-configuration) section below.

---

## Jenkins Pipeline Configuration

### Pre-Build Step

Add an **Execute Shell** build step with the contents of `pre_build-step_script.txt`. This script:

- Creates a Maven project structure from scratch inside the Jenkins workspace
- Generates the `LogGenerator.java` source file
- Writes a `pom.xml` targeting Java 17
- Runs `mvn clean package` to compile and produce the JAR

The resulting artifact will be at:
```
log-generator/target/log-generator-1.0.0.jar
```

### Post-Build Step

Configure a **Send files or execute commands over SSH** post-build action (requires the **Publish Over SSH** Jenkins plugin) using the settings from `post_build_script.txt`:

| Field            | Value                                    |
|------------------|------------------------------------------|
| Source Files     | `log-generator/target/log-generator-1.0.0.jar` |
| Remove Prefix    | `log-generator/target`                   |
| Remote Directory | `/`                                      |
| Exec Command     | *(see below)*                            |

**Exec Command:**
```bash
cat << 'EOF' > /root/final.sh
#!/bin/bash
pkill -f log-generator || true

APP_ENV=prod nohup /usr/bin/java -jar /root/log-generator-1.0.0.jar > /root/app.log 2>&1 &

sleep 2
EOF

chmod +x /root/final.sh
sh /root/final.sh
```

This will kill any previously running instance and restart the application in the background with `APP_ENV=prod`.

---

## How It Works

### LogGenerator Application

The `LogGenerator.java` application runs as an infinite loop, writing structured JSON log entries every second to a log file (`/root/app.log`).

Each log entry is one of three types based on a random distribution:

| Type    | Probability | Meaning                        |
|---------|-------------|--------------------------------|
| `INFO`  | ~60%        | Successful request processed   |
| `WARN`  | ~20%        | High response time detected    |
| `ERROR` | ~20%        | Unhandled exception / DB timeout |

---

## Log Output Format

Each log line is a structured JSON object:

```json
{
  "timestamp": "2025-01-15T10:30:45.123",
  "level": "INFO",
  "service": "log-generator-service",
  "env": "prod",
  "requestId": "a3f1c2d4-...",
  "message": "Request processed successfully",
  "latency_ms": 342,
  "error": null
}
```

View live logs on node01:

```bash
tail -f /root/app.log
```

---

## Troubleshooting

| Issue | Likely Cause | Fix |
|-------|-------------|-----|
| `bad interpreter: No such file or directory` | Windows line endings in script | Run `dos2unix Final_script.sh` |
| `Missing required tools: sshpass` | sshpass not installed | `apt install sshpass -y` |
| `Could not retrieve node01 IP` | kubectl not configured | Verify `kubectl get nodes` works |
| SSH connection refused to node01 | Root SSH not allowed | Set `PermitRootLogin yes` in `/etc/ssh/sshd_config` |
| JAR runs but no logs produced | `JAVA_HOME` not set on node01 | Configure `JAVA_HOME` and verify `java -version` |
| Jenkins admin password not shown | Jenkins slow to start | Run manually: `docker exec jenkins bash -c 'cat /var/jenkins_home/secrets/initialAdminPassword'` |

---

## References

- [Jenkins Docker Hub](https://hub.docker.com/r/jenkins/jenkins)
- [Publish Over SSH Plugin](https://plugins.jenkins.io/publish-over-ssh/)
- [Maven Getting Started](https://maven.apache.org/guides/getting-started/)
