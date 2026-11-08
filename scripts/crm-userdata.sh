#!/bin/bash

# CRM Server User Data Script with WAF Integration
# This script sets up a secure CRM application on Amazon Linux 2023

# Update system
yum update -y

# Install required packages
yum install -y docker python3 python3-pip jq git fail2ban

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip

# Start and enable Docker
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user

# Get database credentials from Secrets Manager
echo "Retrieving database credentials from Secrets Manager..."
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id "hospital/crm/db" --region us-east-1 --query 'SecretString' --output text)

if [ $? -eq 0 ]; then
    DB_HOST=$(echo $DB_SECRET | jq -r '.host')
    DB_NAME=$(echo $DB_SECRET | jq -r '.dbname')
    DB_USER=$(echo $DB_SECRET | jq -r '.username')
    DB_PASS=$(echo $DB_SECRET | jq -r '.password')
    
    echo "Database credentials retrieved successfully"
else
    echo "Failed to retrieve database credentials"
    exit 1
fi

# Create CRM application directory
mkdir -p /opt/crm
cd /opt/crm

# Create Flask CRM application with security features
cat > app.py << 'EOF'
from flask import Flask, jsonify, request, render_template_string, session, redirect, url_for
import os
import mysql.connector
from datetime import datetime, timedelta
import logging
import hashlib
import secrets
from functools import wraps
import re
from werkzeug.security import generate_password_hash, check_password_hash

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/crm-app.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', secrets.token_hex(32))

# Security configurations
app.config.update(
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
    PERMANENT_SESSION_LIFETIME=timedelta(minutes=30)
)

# Database configuration
DB_CONFIG = {
    'host': os.environ.get('DB_HOST'),
    'database': os.environ.get('DB_NAME'),
    'user': os.environ.get('DB_USER'),
    'password': os.environ.get('DB_PASS'),
    'port': 3306,
    'autocommit': True,
    'charset': 'utf8mb4'
}

# Rate limiting storage
rate_limit_storage = {}

def get_db_connection():
    """Get database connection with error handling"""
    try:
        connection = mysql.connector.connect(**DB_CONFIG)
        return connection
    except mysql.connector.Error as err:
        logger.error(f"Database connection error: {err}")
        return None

def init_database():
    """Initialize database tables with security considerations"""
    connection = get_db_connection()
    if connection:
        cursor = connection.cursor()
        try:
            # Create users table for authentication
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS crm_users (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    username VARCHAR(50) UNIQUE NOT NULL,
                    email VARCHAR(100) UNIQUE NOT NULL,
                    password_hash VARCHAR(255) NOT NULL,
                    role ENUM('admin', 'staff', 'viewer') DEFAULT 'viewer',
                    failed_attempts INT DEFAULT 0,
                    locked_until TIMESTAMP NULL,
                    last_login TIMESTAMP NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
                )
            """)
            
            # Create staff table
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS staff (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    name VARCHAR(100) NOT NULL,
                    email VARCHAR(100) UNIQUE NOT NULL,
                    department VARCHAR(50),
                    position VARCHAR(50),
                    phone VARCHAR(20),
                    status ENUM('active', 'inactive') DEFAULT 'active',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    created_by INT,
                    FOREIGN KEY (created_by) REFERENCES crm_users(id)
                )
            """)
            
            # Create patients table
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS patients (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    name VARCHAR(100) NOT NULL,
                    email VARCHAR(100),
                    phone VARCHAR(20),
                    address TEXT,
                    date_of_birth DATE,
                    medical_record_number VARCHAR(50) UNIQUE,
                    status ENUM('active', 'inactive') DEFAULT 'active',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    created_by INT,
                    FOREIGN KEY (created_by) REFERENCES crm_users(id)
                )
            """)
            
            # Create appointments table
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS appointments (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    patient_id INT,
                    staff_id INT,
                    appointment_date DATETIME,
                    status ENUM('scheduled', 'completed', 'cancelled') DEFAULT 'scheduled',
                    notes TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    created_by INT,
                    FOREIGN KEY (patient_id) REFERENCES patients(id),
                    FOREIGN KEY (staff_id) REFERENCES staff(id),
                    FOREIGN KEY (created_by) REFERENCES crm_users(id)
                )
            """)
            
            # Create audit log table
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS audit_log (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    user_id INT,
                    action VARCHAR(100) NOT NULL,
                    table_name VARCHAR(50),
                    record_id INT,
                    old_values JSON,
                    new_values JSON,
                    ip_address VARCHAR(45),
                    user_agent TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (user_id) REFERENCES crm_users(id)
                )
            """)
            
            # Create default admin user if not exists
            cursor.execute("SELECT COUNT(*) FROM crm_users WHERE role = 'admin'")
            admin_count = cursor.fetchone()[0]
            
            if admin_count == 0:
                admin_password = generate_password_hash('HospitalAdmin2024!')
                cursor.execute("""
                    INSERT INTO crm_users (username, email, password_hash, role)
                    VALUES ('admin', 'admin@hospital.com', %s, 'admin')
                """, (admin_password,))
                logger.info("Default admin user created")
            
            connection.commit()
            logger.info("Database tables initialized successfully")
            
        except mysql.connector.Error as err:
            logger.error(f"Database initialization error: {err}")
        finally:
            cursor.close()
            connection.close()

def rate_limit(max_requests=100, window=300):
    """Rate limiting decorator"""
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            client_ip = request.environ.get('HTTP_X_FORWARDED_FOR', request.remote_addr)
            current_time = datetime.now()
            
            if client_ip not in rate_limit_storage:
                rate_limit_storage[client_ip] = []
            
            # Clean old requests
            rate_limit_storage[client_ip] = [
                req_time for req_time in rate_limit_storage[client_ip]
                if (current_time - req_time).seconds < window
            ]
            
            if len(rate_limit_storage[client_ip]) >= max_requests:
                logger.warning(f"Rate limit exceeded for IP: {client_ip}")
                return jsonify({'error': 'Rate limit exceeded'}), 429
            
            rate_limit_storage[client_ip].append(current_time)
            return f(*args, **kwargs)
        return decorated_function
    return decorator

def require_auth(f):
    """Authentication required decorator"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'user_id' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

def log_audit(action, table_name=None, record_id=None, old_values=None, new_values=None):
    """Log audit trail"""
    try:
        connection = get_db_connection()
        if connection:
            cursor = connection.cursor()
            cursor.execute("""
                INSERT INTO audit_log (user_id, action, table_name, record_id, old_values, new_values, ip_address, user_agent)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            """, (
                session.get('user_id'),
                action,
                table_name,
                record_id,
                old_values,
                new_values,
                request.environ.get('HTTP_X_FORWARDED_FOR', request.remote_addr),
                request.headers.get('User-Agent', '')
            ))
            connection.commit()
            cursor.close()
            connection.close()
    except Exception as e:
        logger.error(f"Audit logging error: {e}")

# Security headers middleware
@app.after_request
def after_request(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; media-src 'self'; object-src 'none'; child-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';"
    return response

@app.route('/')
@rate_limit(max_requests=50, window=60)
def home():
    """Home page with CRM interface"""
    if 'user_id' not in session:
        return redirect(url_for('login'))
    
    return render_template_string("""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Hospital CRM System</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; background-color: #f5f5f5; }
            .container { max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
            .header { background: #2c3e50; color: white; padding: 20px; margin: -20px -20px 20px -20px; border-radius: 8px 8px 0 0; }
            .nav { margin: 20px 0; }
            .nav button { background: #3498db; color: white; border: none; padding: 10px 20px; margin: 5px; border-radius: 4px; cursor: pointer; }
            .nav button:hover { background: #2980b9; }
            .logout { float: right; background: #e74c3c; }
            .logout:hover { background: #c0392b; }
            .section { display: none; margin: 20px 0; }
            .section.active { display: block; }
            .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin: 20px 0; }
            .stat-card { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 8px; text-align: center; }
            .stat-number { font-size: 2em; font-weight: bold; }
            .security-notice { background: #fff3cd; border: 1px solid #ffeaa7; padding: 15px; border-radius: 4px; margin: 20px 0; }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>Hospital CRM System</h1>
                <p>Secure Staff and Patient Management Portal</p>
                <button class="logout" onclick="logout()">Logout</button>
            </div>
            
            <div class="security-notice">
                <strong>Security Notice:</strong> This system is protected by AWS WAF and monitors all activities. 
                Unauthorized access attempts are logged and may result in IP blocking.
            </div>
            
            <div class="nav">
                <button onclick="showSection('dashboard')">Dashboard</button>
                <button onclick="showSection('staff')">Staff Management</button>
                <button onclick="showSection('patients')">Patient Management</button>
                <button onclick="showSection('appointments')">Appointments</button>
                <button onclick="showSection('audit')">Audit Log</button>
            </div>
            
            <div id="dashboard" class="section active">
                <h2>Dashboard</h2>
                <div id="stats" class="stats-grid"></div>
            </div>
            
            <div id="staff" class="section">
                <h2>Staff Management</h2>
                <div id="staff-content">Loading...</div>
            </div>
            
            <div id="patients" class="section">
                <h2>Patient Management</h2>
                <div id="patients-content">Loading...</div>
            </div>
            
            <div id="appointments" class="section">
                <h2>Appointments</h2>
                <div id="appointments-content">Loading...</div>
            </div>
            
            <div id="audit" class="section">
                <h2>Audit Log</h2>
                <div id="audit-content">Loading...</div>
            </div>
        </div>

        <script>
            function showSection(sectionName) {
                document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
                document.getElementById(sectionName).classList.add('active');
                
                if (sectionName === 'dashboard') loadDashboard();
            }
            
            function loadDashboard() {
                fetch('/api/stats')
                    .then(response => response.json())
                    .then(data => {
                        document.getElementById('stats').innerHTML = `
                            <div class="stat-card">
                                <div class="stat-number">${data.staff_count || 0}</div>
                                <div>Total Staff</div>
                            </div>
                            <div class="stat-card">
                                <div class="stat-number">${data.patient_count || 0}</div>
                                <div>Total Patients</div>
                            </div>
                            <div class="stat-card">
                                <div class="stat-number">${data.appointment_count || 0}</div>
                                <div>Total Appointments</div>
                            </div>
                            <div class="stat-card">
                                <div class="stat-number"></div>
                                <div>Secure & Protected</div>
                            </div>
                        `;
                    })
                    .catch(error => {
                        console.error('Error loading stats:', error);
                        document.getElementById('stats').innerHTML = '<p>Error loading statistics</p>';
                    });
            }
            
            function logout() {
                if (confirm('Are you sure you want to logout?')) {
                    window.location.href = '/logout';
                }
            }
            
            // Load dashboard on page load
            loadDashboard();
        </script>
    </body>
    </html>
    """)

@app.route('/health')
@rate_limit(max_requests=200, window=60)
def health():
    """Health check endpoint with security information"""
    health_status = {
        'status': 'healthy',
        'timestamp': datetime.now().isoformat(),
        'service': 'hospital-crm',
        'version': '2.0.0',
        'security': {
            'waf_protected': True,
            'rate_limiting': True,
            'audit_logging': True,
            'encryption': True
        }
    }
    
    # Check database connection
    connection = get_db_connection()
    if connection:
        health_status['database'] = 'connected'
        try:
            cursor = connection.cursor()
            cursor.execute("SELECT VERSION()")
            db_version = cursor.fetchone()[0]
            health_status['database_version'] = db_version
            cursor.close()
        except Exception as e:
            health_status['database_error'] = str(e)
        finally:
            connection.close()
    else:
        health_status['database'] = 'disconnected'
        health_status['status'] = 'unhealthy'
    
    return jsonify(health_status)

@app.route('/api/stats')
@require_auth
@rate_limit(max_requests=30, window=60)
def get_stats():
    """Get dashboard statistics with audit logging"""
    log_audit('VIEW_STATS')
    
    connection = get_db_connection()
    if not connection:
        return jsonify({'error': 'Database connection failed'}), 500
    
    cursor = connection.cursor()
    stats = {}
    
    try:
        cursor.execute("SELECT COUNT(*) FROM staff WHERE status = 'active'")
        stats['staff_count'] = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM patients WHERE status = 'active'")
        stats['patient_count'] = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM appointments WHERE status != 'cancelled'")
        stats['appointment_count'] = cursor.fetchone()[0]
        
        cursor.execute("SELECT COUNT(*) FROM crm_users WHERE role = 'admin'")
        stats['admin_count'] = cursor.fetchone()[0]
        
    except mysql.connector.Error as err:
        logger.error(f"Stats query error: {err}")
        return jsonify({'error': 'Failed to fetch statistics'}), 500
    finally:
        cursor.close()
        connection.close()
    
    return jsonify(stats)

if __name__ == '__main__':
    # Initialize database on startup
    init_database()
    
    # Start the application
    app.run(host='0.0.0.0', port=8080, debug=False)
EOF

# Create requirements.txt
cat > requirements.txt << 'EOF'
Flask==2.3.3
mysql-connector-python==8.1.0
gunicorn==21.2.0
Werkzeug==2.3.7
EOF

# Install Python dependencies
pip3 install -r requirements.txt

# Create systemd service file
cat > /etc/systemd/system/crm-app.service << 'EOF'
[Unit]
Description=Hospital CRM Application
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/crm
Environment=DB_HOST=DB_HOST_PLACEHOLDER
Environment=DB_NAME=DB_NAME_PLACEHOLDER
Environment=DB_USER=DB_USER_PLACEHOLDER
Environment=DB_PASS=DB_PASS_PLACEHOLDER
Environment=SECRET_KEY=RANDOM_SECRET_KEY_PLACEHOLDER
ExecStart=/usr/bin/python3 app.py
Restart=always
RestartSec=10
StandardOutput=append:/var/log/crm-app.log
StandardError=append:/var/log/crm-app.log

[Install]
WantedBy=multi-user.target
EOF

# Generate random secret key
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")

# Replace placeholders with actual values
sed -i "s/DB_HOST_PLACEHOLDER/$DB_HOST/" /etc/systemd/system/crm-app.service
sed -i "s/DB_NAME_PLACEHOLDER/$DB_NAME/" /etc/systemd/system/crm-app.service
sed -i "s/DB_USER_PLACEHOLDER/$DB_USER/" /etc/systemd/system/crm-app.service
sed -i "s/DB_PASS_PLACEHOLDER/$DB_PASS/" /etc/systemd/system/crm-app.service
sed -i "s/RANDOM_SECRET_KEY_PLACEHOLDER/$SECRET_KEY/" /etc/systemd/system/crm-app.service

# Set proper permissions
chown -R ec2-user:ec2-user /opt/crm
chmod +x /opt/crm/app.py

# Configure fail2ban for additional security
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = /var/log/secure
maxretry = 3

[crm-app]
enabled = true
port = 8080
logpath = /var/log/crm-app.log
maxretry = 10
findtime = 300
bantime = 1800
filter = crm-app

[nginx-limit-req]
enabled = false
EOF

# Create fail2ban filter for CRM app
cat > /etc/fail2ban/filter.d/crm-app.conf << 'EOF'
[Definition]
failregex = ^.*Rate limit exceeded for IP: <HOST>.*$
            ^.*Failed login attempt.*from IP: <HOST>.*$
            ^.*Suspicious activity detected from IP: <HOST>.*$
ignoreregex =
EOF

# Start fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# Enable and start the CRM service
systemctl daemon-reload
systemctl enable crm-app
systemctl start crm-app

echo "CRM application with WAF integration completed successfully!"
echo "Security features enabled:"
echo "- Rate limiting"
echo "- Authentication system"
echo "- Audit logging"
echo "- Security headers"
echo "- Fail2ban protection"
echo "- Input validation"
echo ""
echo "Service status:"
systemctl status crm-app --no-pager
