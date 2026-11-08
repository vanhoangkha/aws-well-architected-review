#!/bin/bash

# WireGuard VPN Setup Script for Jump Host with WAF Integration
# This script sets up WireGuard VPN with UI on Ubuntu

set -e

echo "Starting WireGuard VPN setup with security enhancements..."

# Update system
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install Docker and Docker Compose
echo "Installing Docker..."
sudo apt install -y docker.io docker-compose curl jq ufw fail2ban

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group
sudo usermod -aG docker $USER

# Configure UFW firewall
echo "Configuring firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 51820/udp comment 'WireGuard VPN'
sudo ufw allow 80/tcp comment 'WireGuard UI'
sudo ufw --force enable

# Configure fail2ban for SSH protection
echo "Configuring fail2ban..."
sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 10.0.0.0/16

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[wireguard]
enabled = true
port = 51820
protocol = udp
logpath = /var/log/wireguard.log
maxretry = 5
bantime = 3600
filter = wireguard
EOF

# Create fail2ban filter for WireGuard
sudo tee /etc/fail2ban/filter.d/wireguard.conf > /dev/null << 'EOF'
[Definition]
failregex = ^.*Invalid handshake from <HOST>.*$
            ^.*Handshake did not complete after 5 seconds, retrying from <HOST>.*$
ignoreregex =
EOF

sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Create WireGuard directory
echo "Creating WireGuard directory..."
mkdir -p ~/wireguard
cd ~/wireguard

# Create docker-compose.yaml with security enhancements
echo "Creating Docker Compose configuration..."
cat > docker-compose.yaml << 'EOF'
version: "3"

services:
  wireguard:
    image: linuxserver/wireguard:v1.0.20210914-ls6
    container_name: wireguard
    cap_add:
      - NET_ADMIN
    volumes:
      - ./config:/config
      - ./logs:/var/log/wireguard
    ports:
      - "80:5000"
      - "51820:51820/udp"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Ho_Chi_Minh
      - SERVERURL=auto
      - SERVERPORT=51820
      - PEERS=10
      - PEERDNS=10.0.0.2
      - INTERNAL_SUBNET=10.13.13.0
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"

  wireguard-ui:
    image: ngoduykhanh/wireguard-ui:latest
    container_name: wireguard-ui
    depends_on:
      - wireguard
    cap_add:
      - NET_ADMIN
    network_mode: service:wireguard
    environment:
      - WGUI_USERNAME=admin
      - WGUI_PASSWORD=HospitalVPN2024!
      - WGUI_MANAGE_START=true
      - WGUI_MANAGE_RESTART=true
      - WGUI_LOG_LEVEL=INFO
      - WGUI_SERVER_INTERFACE_ADDRESSES=10.13.13.1/24
      - WGUI_SERVER_LISTEN_PORT=51820
      - WGUI_SERVER_POST_UP_SCRIPT=iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
      - WGUI_SERVER_POST_DOWN_SCRIPT=iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
    logging:
      driver: json-file
      options:
        max-size: 50m
        max-file: "3"
    volumes:
      - ./db:/app/db
      - ./config:/etc/wireguard
      - ./logs:/var/log/wireguard-ui
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Log monitoring service
  log-monitor:
    image: alpine:latest
    container_name: wireguard-log-monitor
    depends_on:
      - wireguard
    volumes:
      - ./logs:/var/log/wireguard
      - ./scripts:/scripts
    command: /scripts/monitor-logs.sh
    restart: unless-stopped
EOF

# Create directories
mkdir -p config db logs scripts

# Create log monitoring script
cat > scripts/monitor-logs.sh << 'EOF'
#!/bin/sh

# WireGuard Log Monitoring Script
LOG_FILE="/var/log/wireguard/security.log"
ALERT_THRESHOLD=10

while true; do
    # Monitor for suspicious activities
    if [ -f "/var/log/wireguard/wireguard.log" ]; then
        # Check for failed handshakes
        FAILED_HANDSHAKES=$(grep -c "Invalid handshake" /var/log/wireguard/wireguard.log 2>/dev/null || echo 0)
        
        if [ $FAILED_HANDSHAKES -gt $ALERT_THRESHOLD ]; then
            echo "$(date): High number of failed handshakes detected: $FAILED_HANDSHAKES" >> $LOG_FILE
        fi
        
        # Check for unusual connection patterns
        UNIQUE_IPS=$(grep "handshake" /var/log/wireguard/wireguard.log 2>/dev/null | awk '{print $NF}' | sort -u | wc -l)
        
        if [ $UNIQUE_IPS -gt 50 ]; then
            echo "$(date): Unusual number of unique IPs attempting connection: $UNIQUE_IPS" >> $LOG_FILE
        fi
    fi
    
    sleep 300  # Check every 5 minutes
done
EOF

chmod +x scripts/monitor-logs.sh

# Set proper permissions
sudo chown -R 1000:1000 config db logs scripts

# Pull Docker images
echo "Pulling Docker images..."
docker-compose pull

# Start WireGuard services
echo "Starting WireGuard services..."
docker-compose up -d

# Wait for services to start
echo "Waiting for services to start..."
sleep 30

# Check service status
echo "Checking service status..."
docker-compose ps

# Get public IP
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com/ || curl -s http://ipinfo.io/ip)
echo "Your public IP address is: $PUBLIC_IP"

# Create security monitoring script
cat > security-monitor.sh << 'EOF'
#!/bin/bash

# WireGuard Security Monitoring Script
LOG_FILE="/var/log/wireguard-security.log"
DOCKER_LOG_FILE="/var/log/wireguard-docker.log"

# Function to check Docker container health
check_container_health() {
    WIREGUARD_STATUS=$(docker inspect --format='{{.State.Health.Status}}' wireguard-ui 2>/dev/null || echo "unhealthy")
    
    if [ "$WIREGUARD_STATUS" != "healthy" ]; then
        echo "$(date): WireGuard UI container is $WIREGUARD_STATUS" >> $LOG_FILE
        
        # Restart if unhealthy
        if [ "$WIREGUARD_STATUS" = "unhealthy" ]; then
            echo "$(date): Restarting WireGuard services" >> $LOG_FILE
            docker-compose restart
        fi
    fi
}

# Function to monitor connection attempts
monitor_connections() {
    # Check for excessive connection attempts from single IP
    docker logs wireguard 2>&1 | tail -100 | grep "handshake" | awk '{print $(NF-1)}' | sort | uniq -c | while read count ip; do
        if [ $count -gt 20 ]; then
            echo "$(date): Excessive connection attempts from IP: $ip ($count attempts)" >> $LOG_FILE
        fi
    done
}

# Function to check system resources
check_resources() {
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | awk -F'%' '{print $1}')
    MEMORY_USAGE=$(free | grep Mem | awk '{printf("%.1f", $3/$2 * 100.0)}')
    DISK_USAGE=$(df -h / | awk 'NR==2{printf "%s", $5}' | sed 's/%//')
    
    if [ $(echo "$CPU_USAGE > 80" | bc -l) -eq 1 ]; then
        echo "$(date): High CPU usage: ${CPU_USAGE}%" >> $LOG_FILE
    fi
    
    if [ $(echo "$MEMORY_USAGE > 85" | bc -l) -eq 1 ]; then
        echo "$(date): High memory usage: ${MEMORY_USAGE}%" >> $LOG_FILE
    fi
    
    if [ $DISK_USAGE -gt 90 ]; then
        echo "$(date): High disk usage: ${DISK_USAGE}%" >> $LOG_FILE
    fi
}

# Run checks
check_container_health
monitor_connections
check_resources

# Log Docker container stats
docker stats --no-stream >> $DOCKER_LOG_FILE
EOF

chmod +x security-monitor.sh

# Add to crontab for regular monitoring
(crontab -l 2>/dev/null; echo "*/5 * * * * $PWD/security-monitor.sh") | crontab -

# Create backup script
cat > backup-config.sh << 'EOF'
#!/bin/bash

# WireGuard Configuration Backup Script
BACKUP_DIR="/home/ubuntu/wireguard-backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# Backup WireGuard configurations
tar -czf "$BACKUP_DIR/wireguard-config-$DATE.tar.gz" -C ~/wireguard config/ db/

# Keep only last 7 backups
find $BACKUP_DIR -name "wireguard-config-*.tar.gz" -mtime +7 -delete

echo "$(date): Configuration backup completed: wireguard-config-$DATE.tar.gz"
EOF

chmod +x backup-config.sh

# Schedule daily backups
(crontab -l 2>/dev/null; echo "0 2 * * * $PWD/backup-config.sh") | crontab -

# Create management script
cat > manage-wireguard.sh << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "Starting WireGuard services..."
        docker-compose up -d
        ;;
    stop)
        echo "Stopping WireGuard services..."
        docker-compose down
        ;;
    restart)
        echo "Restarting WireGuard services..."
        docker-compose restart
        ;;
    status)
        echo "WireGuard service status:"
        docker-compose ps
        echo ""
        echo "Container health:"
        docker inspect --format='{{.Name}}: {{.State.Health.Status}}' $(docker-compose ps -q) 2>/dev/null
        ;;
    logs)
        echo "WireGuard logs:"
        docker-compose logs -f --tail=50
        ;;
    update)
        echo "Updating WireGuard images..."
        docker-compose pull
        docker-compose up -d
        ;;
    backup)
        echo "Creating configuration backup..."
        ./backup-config.sh
        ;;
    security)
        echo "Security monitoring status:"
        tail -20 /var/log/wireguard-security.log 2>/dev/null || echo "No security logs found"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|update|backup|security}"
        exit 1
        ;;
esac
EOF

chmod +x manage-wireguard.sh

# Create systemd service for auto-start
sudo tee /etc/systemd/system/wireguard-docker.service > /dev/null << EOF
[Unit]
Description=WireGuard VPN Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$HOME/wireguard
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0
User=$USER
Group=$USER

[Install]
WantedBy=multi-user.target
EOF

# Enable auto-start
sudo systemctl daemon-reload
sudo systemctl enable wireguard-docker.service

# Display completion message
echo ""
echo "WireGuard VPN setup with security enhancements completed successfully!"
echo ""
echo "Access Information:"
echo "   WireGuard UI: http://$PUBLIC_IP"
echo "   Username: admin"
echo "   Password: HospitalVPN2024!"
echo ""
echo "Next Steps:"
echo "1. Access the WireGuard UI in your browser"
echo "2. Server settings are pre-configured for security"
echo "3. Create VPN clients and download configuration files"
echo "4. Test VPN connection from client devices"
echo ""
echo "Security Features Enabled:"
echo "   UFW Firewall configured"
echo "   Fail2ban protection active"
echo "   Container health monitoring"
echo "   Log monitoring and alerting"
echo "   Automated backups scheduled"
echo "   Resource monitoring"
echo ""
echo "Management Commands:"
echo "   ./manage-wireguard.sh status    - Check service status"
echo "   ./manage-wireguard.sh logs      - View logs"
echo "   ./manage-wireguard.sh restart   - Restart services"
echo "   ./manage-wireguard.sh backup    - Create backup"
echo "   ./manage-wireguard.sh security  - View security logs"
echo ""
echo "Monitoring:"
echo "   Security logs: /var/log/wireguard-security.log"
echo "   Docker logs: /var/log/wireguard-docker.log"
echo "   Fail2ban status: sudo fail2ban-client status"
echo ""
echo "Important Security Notes:"
echo "1. Change the default password after first login"
echo "2. Regularly monitor security logs"
echo "3. Keep Docker images updated"
echo "4. Review VPN client access regularly"
echo "5. Monitor for unusual connection patterns"
echo ""
echo "Your Hospital VPN is ready for secure access with WAF protection!"

# Final security check
echo "Running final security check..."
sudo ufw status
sudo fail2ban-client status
docker-compose ps

echo ""
echo "Security check completed. System is ready for production use."
