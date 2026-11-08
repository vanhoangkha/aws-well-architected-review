# Hospital Management System - AWS Infrastructure Setup Guide

[![AWS](https://img.shields.io/badge/AWS-Cloud-orange)](https://aws.amazon.com/)
[![MySQL](https://img.shields.io/badge/Database-MySQL-blue)](https://aws.amazon.com/rds/)
[![Security](https://img.shields.io/badge/Security-WAF+KMS-green)](https://aws.amazon.com/security/)
[![WAF](https://img.shields.io/badge/AWS-WAF-red)](https://aws.amazon.com/waf/)

Hướng dẫn chi tiết từng bước tạo hạ tầng AWS cho Hệ thống Quản lý Bệnh viện bằng AWS Console với MySQL RDS, Secrets Manager, KMS encryption và WAF protection.

## Kiến trúc Hệ thống

```
                                    ┌─────────────────────────────────────┐
                                    │              Internet               │
                                    └─────────────────┬───────────────────┘
                                                      │
                                    ┌─────────────────▼───────────────────┐
                                    │           AWS WAF v2                │
                                    │    (SQL Injection, XSS, Rate       │
                                    │     Limiting, Geo Blocking)         │
                                    └─────────────────┬───────────────────┘
                                                      │
                                    ┌─────────────────▼───────────────────┐
                                    │          CloudFront CDN             │
                                    │       (Global Distribution)         │
                                    └─────────────────┬───────────────────┘
                                                      │
                                    ┌─────────────────▼───────────────────┐
                                    │      Application Load Balancer     │
                                    │         (Multi-AZ, SSL)            │
                                    └─────────┬───────────────────┬───────┘
                                              │                   │
                        ┌─────────────────────▼─────┐   ┌─────────▼─────────────────────┐
                        │    WordPress Server       │   │      CRM Server               │
                        │   (Patient Portal)        │   │   (Staff Management)          │
                        │   Private Subnet 1A       │   │   Private Subnet 1A           │
                        └─────────┬─────────────────┘   └─────────┬─────────────────────┘
                                  │                               │
                                  └─────────────┬─────────────────┘
                                                │
                                  ┌─────────────▼─────────────────┐
                                  │         RDS MySQL             │
                                  │    (KMS Encrypted, Multi-AZ)  │
                                  │     Secrets Manager           │
                                  │       Database Subnets        │
                                  └───────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                VPN Access Layer                                     │
│                                                                                     │
│  ┌─────────────────┐    WireGuard VPN     ┌─────────────────────────────────────┐   │
│  │  Admin Users    │ ◄─────────────────── │         Jump Host                   │   │
│  │   (Laptops)     │                      │      (Ubuntu 24.04)                │   │
│  │                 │                      │   - WireGuard Server                │   │
│  └─────────────────┘                      │   - Docker Containers               │   │
│                                           │   - Management UI                   │   │
│                                           │   Public Subnet 1A                  │   │
│                                           └─────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Mục lục

- [Yêu cầu trước khi bắt đầu](#yêu-cầu-trước-khi-bắt-đầu)
- [Bước 1: Tạo KMS Key](#bước-1-tạo-kms-key)
- [Bước 2: Tạo VPC và Network](#bước-2-tạo-vpc-và-network)
- [Bước 3: Tạo Secrets Manager](#bước-3-tạo-secrets-manager)
- [Bước 4: Tạo RDS MySQL](#bước-4-tạo-rds-mysql)
- [Bước 5: Tạo Jump Host và VPN](#bước-5-tạo-jump-host-và-vpn)
- [Bước 6: Tạo Application Servers](#bước-6-tạo-application-servers)
- [Bước 7: Tạo Application Load Balancer](#bước-7-tạo-application-load-balancer)
- [Bước 8: Tạo SSL Certificate](#bước-8-tạo-ssl-certificate)
- [Bước 9: Tạo WAF Web ACL](#bước-9-tạo-waf-web-acl)
- [Bước 10: Tạo CloudFront Distribution](#bước-10-tạo-cloudfront-distribution)
- [Bước 11: Cấu hình DNS](#bước-11-cấu-hình-dns)
- [Bước 12: Testing và Monitoring](#bước-12-testing-và-monitoring)
- [Troubleshooting](#troubleshooting)

## Yêu cầu trước khi bắt đầu

### Tài khoản và Quyền
- AWS Account với quyền Administrator
- Domain name đã đăng ký (ví dụ: hospital.com)
- SSH client (Terminal/PuTTY)

### Thông tin cần chuẩn bị
```
Domain: hospital.com
Subdomain: 
  - www.hospital.com (WordPress)
  - crm.hospital.com (CRM)
  
Network CIDR: 10.0.0.0/16
Region: us-east-1 (N. Virginia)
```

## Bước 1: Sử dụng KMS Default Keys

### 1.1 Xác nhận KMS Default Keys

AWS cung cấp sẵn các default managed keys cho từng service:

1. **RDS Default Key**
   - Key alias: `alias/aws/rds`
   - Tự động có sẵn trong account
   - Không cần tạo thêm

2. **Secrets Manager Default Key**
   - Key alias: `alias/aws/secretsmanager`
   - Tự động có sẵn trong account
   - Không cần tạo thêm

3. **Kiểm tra Default Keys**
   - AWS Console → Services → Key Management Service (KMS)
   - AWS managed keys → Tìm:
     - `aws/rds` (cho RDS encryption)
     - `aws/secretsmanager` (cho Secrets Manager)

**Lưu ý:** Sử dụng default keys giúp đơn giản hóa setup và giảm chi phí (AWS managed keys miễn phí).

## Bước 2: Tạo VPC và Network

### 2.1 Tạo VPC

1. **Truy cập VPC Console**
   - AWS Console → Services → VPC
   - Click "Create VPC"

2. **Chọn VPC and more**
   ```
   Name tag auto-generation: Hospital
   IPv4 CIDR block: 10.0.0.0/16
   IPv6 CIDR block: No IPv6 CIDR block
   Tenancy: Default
   
   Number of Availability Zones: 2
   Number of public subnets: 2
   Number of private subnets: 2
   
   NAT gateways: In 1 AZ
   VPC endpoints: None
   
   DNS options:
   Enable DNS hostnames
   Enable DNS resolution
   ```

3. **Click "Create VPC"**
   - Đợi khoảng 2-3 phút để tạo xong

### 2.2 Tạo Database Subnets

1. **Tạo DB Subnet 1**
   - VPC → Subnets → Create subnet
   ```
   VPC ID: Chọn Hospital-vpc
   Subnet name: Hospital-db-subnet-1a
   Availability Zone: us-east-1a
   IPv4 CIDR block: 10.0.20.0/24
   ```

2. **Tạo DB Subnet 2**
   ```
   Subnet name: Hospital-db-subnet-1b
   Availability Zone: us-east-1b
   IPv4 CIDR block: 10.0.21.0/24
   ```

### 2.3 Tạo DB Subnet Group

1. **Truy cập RDS Console**
   - AWS Console → Services → RDS
   - Left menu → Subnet groups → Create DB subnet group

2. **Cấu hình Subnet Group**
   ```
   Name: hospital-db-subnet-group
   Description: Hospital database subnet group
   VPC: Hospital-vpc
   
   Availability Zones:
   - us-east-1a
   - us-east-1b
   
   Subnets:
   - Hospital-db-subnet-1a (10.0.20.0/24)
   - Hospital-db-subnet-1b (10.0.21.0/24)
   ```

3. **Click "Create"**

## Bước 3: Tạo Secrets Manager

### 3.1 Tạo RDS Master Secret

1. **Truy cập Secrets Manager**
   - AWS Console → Services → Secrets Manager
   - Click "Store a new secret"

2. **Secret Type**
   ```
   Secret type: Credentials for Amazon RDS database
   Database engine: MySQL
   
   Credentials:
   User name: admin
   Password: HospitalRDS2024!@#$
   
   Encryption key: (default) aws/secretsmanager
   ```

3. **Database Configuration**
   ```
   Database: (Để trống - sẽ cập nhật sau)
   ```
   - Click "Next"

4. **Secret Name**
   ```
   Secret name: hospital/rds/master
   Description: Hospital RDS master credentials
   
   Tags:
   - Key: Project, Value: Hospital-Management
   - Key: Type, Value: Database-Credentials
   ```

5. **Automatic Rotation**
   ```
   Automatic rotation: Disable (có thể enable sau)
   ```
   - Click "Next" → "Store"

### 3.2 Tạo WordPress Database Secret

1. **Tạo Secret mới**
   ```
   Secret type: Other type of secret
   
   Key/value pairs:
   username: wp_user
   password: WordPressDB2024!@#$
   engine: mysql
   host: (để trống - sẽ update sau khi tạo RDS)
   port: 3306
   dbname: wordpress_db
   
   Encryption key: (default) aws/secretsmanager
   ```

2. **Secret Name**
   ```
   Secret name: hospital/wordpress/db
   Description: WordPress database credentials
   ```

### 3.3 Tạo CRM Database Secret

1. **Tạo Secret tương tự**
   ```
   Key/value pairs:
   username: crm_user
   password: CRMDB2024!@#$
   engine: mysql
   host: (để trống)
   port: 3306
   dbname: crm_db
   
   Secret name: hospital/crm/db
   Description: CRM database credentials
   ```

## Bước 4: Tạo RDS MySQL

### 4.1 Tạo Security Group cho RDS

1. **Tạo RDS Security Group**
   - EC2 Console → Security Groups → Create security group
   ```
   Security group name: hospital-rds-sg
   Description: Hospital RDS MySQL security group
   VPC: Hospital-vpc
   ```

2. **Inbound Rules**
   ```
   Type: MySQL/Aurora
   Protocol: TCP
   Port: 3306
   Source: 10.0.10.0/24 (Private subnet 1)
   Description: WordPress server access
   
   Type: MySQL/Aurora
   Protocol: TCP
   Port: 3306
   Source: 10.0.11.0/24 (Private subnet 2)
   Description: CRM server access
   
   Type: MySQL/Aurora
   Protocol: TCP
   Port: 3306
   Source: 10.0.1.0/24 (Public subnet - Jump host)
   Description: Jump host admin access
   ```

### 4.2 Tạo RDS Instance

1. **Truy cập RDS Console**
   - RDS → Databases → Create database

2. **Database Creation Method**
   ```
   Choose a database creation method: Standard create
   ```

3. **Engine Options**
   ```
   Engine type: MySQL
   Engine Version: MySQL 8.0.35
   Templates: Production (hoặc Free tier cho testing)
   ```

4. **Settings**
   ```
   DB instance identifier: hospital-db
   
   Credentials Settings:
   Master username: admin
   Manage master credentials in AWS Secrets Manager
   Master credentials: Use the hospital/rds/master secret
   ```

5. **DB Instance Class**
   ```
   DB instance class: 
   - db.t3.micro (Free tier)
   - db.t3.small (Production recommended)
   
   Storage type: General Purpose SSD (gp2)
   Allocated storage: 20 GiB
   Enable storage autoscaling
   Maximum storage threshold: 100 GiB
   ```

6. **Connectivity**
   ```
   Virtual private cloud (VPC): Hospital-vpc
   DB subnet group: hospital-db-subnet-group
   Public access: No
   VPC security groups: hospital-rds-sg
   Availability Zone: No preference
   Database port: 3306
   ```

7. **Database Authentication**
   ```
   Database authentication options: Password authentication
   ```

8. **Additional Configuration**
   ```
   Initial database name: (để trống)
   
   Backup:
   Enable automated backups
   Backup retention period: 7 days
   Backup window: 03:00-04:00 UTC
   
   Encryption:
   Enable encryption
   AWS KMS key: (default) aws/rds
   
   Monitoring:
   Enable Enhanced monitoring
   Monitoring Role: Default
   Granularity: 60 seconds
   
   Maintenance:
   Enable auto minor version upgrade
   Maintenance window: Sun 04:00-05:00 UTC
   
   Deletion protection:
   Enable deletion protection
   ```

9. **Click "Create database"**
   - Đợi 10-15 phút để RDS được tạo

### 4.3 Cập nhật Secrets Manager với RDS Endpoint

1. **Lấy RDS Endpoint**
   - RDS → Databases → hospital-db
   - Copy **Endpoint** (ví dụ: hospital-db.xxxxxx.us-east-1.rds.amazonaws.com)

2. **Cập nhật WordPress Secret**
   - Secrets Manager → hospital/wordpress/db
   - Click "Retrieve secret value" → "Edit"
   - Update field `host` với RDS endpoint
   - Click "Save"

3. **Cập nhật CRM Secret**
   - Tương tự với hospital/crm/db

### 4.4 Tạo Database và Users

1. **Connect tới RDS từ Jump Host** (sẽ tạo ở bước sau)
   ```sql
   mysql -h hospital-db.xxxxxx.us-east-1.rds.amazonaws.com -u admin -p
   ```

2. **Tạo Databases**
   ```sql
   CREATE DATABASE wordpress_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE DATABASE crm_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   ```

3. **Tạo Users**
   ```sql
   CREATE USER 'wp_user'@'%' IDENTIFIED BY 'WordPressDB2024!@#$';
   CREATE USER 'crm_user'@'%' IDENTIFIED BY 'CRMDB2024!@#$';
   
   GRANT ALL PRIVILEGES ON wordpress_db.* TO 'wp_user'@'%';
   GRANT ALL PRIVILEGES ON crm_db.* TO 'crm_user'@'%';
   
   FLUSH PRIVILEGES;
   EXIT;
   ```

---

**Hướng dẫn chi tiết các bước tiếp theo:**
- [Phần 2: Bước 5-12](docs/DEPLOYMENT-PART2.md) - Jump Host, Application Servers, ALB, SSL, WAF, CloudFront

**Tài liệu bổ sung:**
- [KMS Default Keys](docs/KMS-DEFAULT-KEYS.md) - Hướng dẫn sử dụng AWS managed keys
- [Cấu hình WAF chi tiết](docs/WAF-CONFIGURATION.md)
- [Scripts tự động hóa](scripts/)

**Scripts có sẵn:**
- `scripts/wordpress-userdata.sh` - Setup WordPress với security
- `scripts/crm-userdata.sh` - Setup CRM với security  
- `scripts/wireguard-setup.sh` - Setup WireGuard VPN

## Lưu ý quan trọng

### KMS Default Keys
- **Miễn phí hoàn toàn** - Không tính phí key usage
- **AWS managed** - Tự động rotation và maintenance
- **Đơn giản setup** - Không cần tạo custom keys
- **Phù hợp POC/Production** - Đáp ứng yêu cầu bảo mật cơ bản
- [Chi tiết về KMS Default Keys](docs/KMS-DEFAULT-KEYS.md)

### Bảo mật
- Thay đổi tất cả passwords mặc định
- Cấu hình MFA cho AWS account
- Thường xuyên update security patches
- Monitor WAF logs để phát hiện threats

### Chi phí
- Sử dụng Reserved Instances cho production
- Monitor chi phí qua AWS Cost Explorer
- Setup billing alerts
- Tối ưu hóa storage và compute resources

### Backup
- RDS automated backup: 7 ngày
- Manual snapshots: hàng tuần
- Test disaster recovery procedures
- Document recovery procedures

## Hỗ trợ

Nếu gặp vấn đề trong quá trình setup:
- Tạo issue trong repository này
- Email: devops@hospital.com
- AWS Support (cho các vấn đề AWS)

---

*Cập nhật lần cuối: 2024-06-18*
*Phiên bản: 2.0.0*
*Được duy trì bởi: Hospital DevOps Team*
