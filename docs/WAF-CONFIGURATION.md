# AWS WAF Configuration Guide

This document provides detailed instructions for configuring AWS WAF v2 to protect the Hospital Management System.

## WAF Overview

AWS WAF (Web Application Firewall) protects your web applications from common web exploits and attacks. For the Hospital Management System, WAF provides:

- **DDoS Protection**: Integration with AWS Shield
- **Rate Limiting**: Prevent abuse and brute force attacks
- **Geo Blocking**: Country-based access control
- **SQL Injection Protection**: Automated detection and blocking
- **XSS Protection**: Cross-site scripting prevention
- **Bot Protection**: Automated bot detection and blocking

## WAF Web ACL Configuration

### Step 1: Create Web ACL

1. **Navigate to WAF Console**
   - AWS Console → Services → WAF & Shield
   - Click "Create web ACL"

2. **Basic Configuration**
   ```yaml
   Name: Hospital-WAF
   Description: WAF for Hospital Management System
   CloudWatch metric name: HospitalWAF
   Resource type: CloudFront distributions
   Region: Global (CloudFront)
   ```

3. **Associated Resources**
   - Select your CloudFront distribution
   - Click "Add"

### Step 2: Add Managed Rule Groups

#### 2.1 Core Rule Set
```yaml
Rule Group: AWS-AWSManagedRulesCommonRuleSet
Priority: 1
Action: Block
Override Actions: None

Rules Included:
- NoUserAgent_HEADER
- UserAgent_BadBots_HEADER
- SizeRestrictions_QUERYSTRING
- SizeRestrictions_Cookie_HEADER
- SizeRestrictions_BODY
- SizeRestrictions_URIPATH
- EC2MetaDataSSRF_BODY
- EC2MetaDataSSRF_COOKIE
- EC2MetaDataSSRF_URIPATH
- EC2MetaDataSSRF_QUERYSTRING
- GenericLFI_QUERYSTRING
- GenericLFI_URIPATH
- GenericLFI_BODY
- RestrictedExtensions_URIPATH
- RestrictedExtensions_QUERYSTRING
- GenericRFI_QUERYSTRING
- GenericRFI_BODY
- GenericRFI_URIPATH
- CrossSiteScripting_COOKIE
- CrossSiteScripting_QUERYSTRING
- CrossSiteScripting_BODY
- CrossSiteScripting_URIPATH
```

#### 2.2 Known Bad Inputs
```yaml
Rule Group: AWS-AWSManagedRulesKnownBadInputsRuleSet
Priority: 2
Action: Block
Override Actions: None

Rules Included:
- Host_localhost_HEADER
- PROPFIND_METHOD
- ExploitablePaths_URIPATH
- BadAuthToken_COOKIE_AUTHORIZATION
```

#### 2.3 SQL Injection Protection
```yaml
Rule Group: AWS-AWSManagedRulesSQLiRuleSet
Priority: 3
Action: Block
Override Actions: None

Rules Included:
- SQLiExtendedPatterns_QUERYSTRING
- SQLiExtendedPatterns_BODY
- SQLi_QUERYSTRING
- SQLi_BODY
- SQLi_COOKIE
- SQLi_URIPATH
```

#### 2.4 Admin Protection
```yaml
Rule Group: AWS-AWSManagedRulesAdminProtectionRuleSet
Priority: 4
Action: Block
Override Actions: 
  - AdminProtection_URIPATH: Count (for monitoring)

Rules Included:
- AdminProtection_URIPATH
```

### Step 3: Custom Rules

#### 3.1 Rate Limiting Rules

**General Rate Limiting**
```yaml
Rule Name: GeneralRateLimit
Type: Rate-based rule
Priority: 10
Rate limit: 2000 requests per 5 minutes
Scope: IP address
Action: Block
Text transformation: None
```

**Login Rate Limiting**
```yaml
Rule Name: LoginRateLimit
Type: Rate-based rule
Priority: 11
Rate limit: 10 requests per 5 minutes
Scope: IP address
Statement:
  - Field to match: URI path
  - Match type: Contains string
  - String to match: wp-login.php
Action: Block
```

**API Rate Limiting**
```yaml
Rule Name: APIRateLimit
Type: Rate-based rule
Priority: 12
Rate limit: 1000 requests per 5 minutes
Scope: IP address
Statement:
  - Field to match: URI path
  - Match type: Starts with string
  - String to match: /api/
Action: Block
```

#### 3.2 Geo Blocking Rule

```yaml
Rule Name: GeoBlockingRule
Type: Regular rule
Priority: 20
Statement:
  - Geographic match
  - Country codes to block:
    - CN (China)
    - RU (Russia)
    - KP (North Korea)
    - IR (Iran)
    - (Add others as needed)
Action: Block
```

#### 3.3 IP Reputation Rule

```yaml
Rule Name: IPReputationRule
Type: Regular rule
Priority: 21
Statement:
  - IP set match
  - IP set: AWSManagedIPsReputationList
Action: Block
```

#### 3.4 Healthcare-Specific Rules

**PHI Protection Rule**
```yaml
Rule Name: PHIProtectionRule
Type: Regular rule
Priority: 30
Statement:
  - OR condition:
    - URI contains: ssn=
    - URI contains: social_security=
    - URI contains: medical_record=
    - Query string contains: patient_id=
    - Query string contains: ssn=
Action: Block
Text transformation: URL decode
```

**Medical Data Access Rule**
```yaml
Rule Name: MedicalDataAccessRule
Type: Rate-based rule
Priority: 31
Rate limit: 100 requests per 5 minutes
Scope: IP address
Statement:
  - OR condition:
    - URI path contains: /patient/
    - URI path contains: /medical-records/
    - URI path contains: /appointments/
Action: Block
```

### Step 4: Rule Exceptions

#### 4.1 Whitelist Trusted IPs

```yaml
Rule Name: TrustedIPWhitelist
Type: Regular rule
Priority: 5
Statement:
  - IP set match
  - IP set: HospitalTrustedIPs
  - IP addresses:
    - 203.0.113.0/24  # Hospital office network
    - 198.51.100.0/24 # Partner clinic network
Action: Allow
```

#### 4.2 Admin Access Exception

```yaml
Rule Name: AdminAccessException
Type: Regular rule
Priority: 6
Statement:
  - AND condition:
    - IP set match: AdminIPSet
    - URI path starts with: /wp-admin/
Action: Allow
```

## WAF Logging Configuration

### Step 1: Enable Logging

1. **Navigate to Web ACL**
   - Select your Web ACL
   - Go to "Logging and metrics" tab
   - Click "Enable logging"

2. **Logging Configuration**
   ```yaml
   Log destination: Amazon CloudWatch Logs
   Log group: /aws/wafv2/hospital-waf
   Log format: JSON
   
   Redacted fields:
     - authorization (request header)
     - cookie (request header)
     - password (query parameter)
     - token (query parameter)
   ```

### Step 2: Log Analysis Queries

**Top Blocked IPs**
```sql
fields @timestamp, httpRequest.clientIP, action
| filter action = "BLOCK"
| stats count() by httpRequest.clientIP
| sort count desc
| limit 20
```

**SQL Injection Attempts**
```sql
fields @timestamp, httpRequest.clientIP, httpRequest.uri, terminatingRuleId
| filter terminatingRuleId like /SQLi/
| sort @timestamp desc
| limit 100
```

**Rate Limited Requests**
```sql
fields @timestamp, httpRequest.clientIP, httpRequest.country
| filter terminatingRuleId like /RateLimit/
| stats count() by httpRequest.clientIP, httpRequest.country
| sort count desc
```

**Geographic Distribution of Blocked Requests**
```sql
fields @timestamp, httpRequest.country, action
| filter action = "BLOCK"
| stats count() by httpRequest.country
| sort count desc
```

## Monitoring and Alerting

### CloudWatch Metrics

**Key Metrics to Monitor:**
- `AllowedRequests`: Number of allowed requests
- `BlockedRequests`: Number of blocked requests
- `SampledRequests`: Number of sampled requests
- `CountedRequests`: Number of counted requests

### CloudWatch Alarms

#### High Block Rate Alarm
```yaml
Alarm Name: WAF-HighBlockRate
Metric: AWS/WAFV2 BlockedRequests
Statistic: Sum
Period: 300 seconds
Threshold: 100
Comparison: GreaterThanThreshold
Evaluation Periods: 2
Treat Missing Data: notBreaching
```

#### SQL Injection Attack Alarm
```yaml
Alarm Name: WAF-SQLInjectionAttack
Metric: AWS/WAFV2 BlockedRequests
Dimensions:
  - WebACL: Hospital-WAF
  - Rule: SQLiRuleGroup
Statistic: Sum
Period: 300 seconds
Threshold: 10
Comparison: GreaterThanThreshold
```

#### Unusual Geographic Activity
```yaml
Alarm Name: WAF-UnusualGeoActivity
Metric: Custom metric from logs
Description: Alert when blocked requests from new countries exceed threshold
```

## WAF Tuning and Optimization

### Performance Optimization

1. **Rule Ordering**
   - Place allow rules first (lower priority numbers)
   - Order rate limiting rules by specificity
   - Place managed rule groups after custom rules

2. **WCU (Web ACL Capacity Units) Management**
   - Monitor WCU usage in CloudWatch
   - Optimize complex rules to reduce WCU consumption
   - Current limit: 1,500 WCUs per Web ACL

### False Positive Reduction

1. **Monitoring Phase**
   - Start with rules in "Count" mode
   - Monitor for 1-2 weeks
   - Analyze blocked legitimate traffic

2. **Rule Tuning**
   ```yaml
   Common False Positives:
     - WordPress admin actions
     - File uploads
     - Rich text editor content
     - Search functionality
   
   Solutions:
     - Create exception rules
     - Adjust rule sensitivity
     - Use custom rules for specific paths
   ```

3. **Exception Rules Example**
   ```yaml
   Rule Name: WordPressAdminException
   Priority: 7
   Statement:
     - AND condition:
       - URI path starts with: /wp-admin/
       - HTTP method: POST
   Action: Allow
   ```

## Incident Response

### Automated Response

1. **Lambda Function for Auto-Blocking**
   ```python
   import boto3
   import json
   
   def lambda_handler(event, context):
       wafv2 = boto3.client('wafv2')
       
       # Parse CloudWatch alarm
       message = json.loads(event['Records'][0]['Sns']['Message'])
       
       if message['AlarmName'] == 'WAF-HighBlockRate':
           # Implement additional blocking rules
           pass
       
       return {'statusCode': 200}
   ```

2. **SNS Notifications**
   ```yaml
   Topic: hospital-waf-alerts
   Subscriptions:
     - Email: security@hospital.com
     - SMS: +1234567890
     - Lambda: auto-response-function
   ```

### Manual Response Procedures

1. **High Attack Volume**
   - Review top attacking IPs
   - Implement temporary IP blocks
   - Adjust rate limiting thresholds
   - Contact AWS Support if needed

2. **New Attack Patterns**
   - Analyze attack signatures
   - Create custom rules
   - Update managed rule groups
   - Document new threats

## Testing and Validation

### WAF Testing Tools

1. **OWASP ZAP**
   ```bash
   # Test SQL injection
   zap-cli quick-scan --self-contained \
     --start-options '-config api.disablekey=true' \
     https://hospital.com
   ```

2. **Custom Test Scripts**
   ```bash
   #!/bin/bash
   # Test rate limiting
   for i in {1..100}; do
     curl -s https://hospital.com/wp-login.php > /dev/null
     echo "Request $i sent"
   done
   ```

3. **Penetration Testing**
   - Schedule regular pen tests
   - Test all WAF rules
   - Validate blocking effectiveness
   - Document findings and improvements

### Validation Checklist

- [ ] SQL injection attempts blocked
- [ ] XSS attempts blocked
- [ ] Rate limiting working correctly
- [ ] Geo blocking effective
- [ ] Legitimate traffic allowed
- [ ] Admin access protected
- [ ] Logging functioning properly
- [ ] Alerts triggering correctly

## Best Practices

### Security Best Practices

1. **Regular Updates**
   - Update managed rule groups monthly
   - Review and update custom rules quarterly
   - Monitor AWS security bulletins

2. **Monitoring**
   - Review WAF logs daily
   - Analyze blocked requests weekly
   - Tune rules based on patterns

3. **Documentation**
   - Document all custom rules
   - Maintain incident response procedures
   - Keep configuration backups

### Cost Optimization

1. **Rule Efficiency**
   - Minimize WCU usage
   - Use efficient rule conditions
   - Avoid overly complex rules

2. **Log Management**
   - Set appropriate log retention
   - Use log filtering to reduce costs
   - Archive old logs to S3

3. **Regular Review**
   - Remove unused rules
   - Optimize rule performance
   - Monitor WAF costs monthly

---

This WAF configuration provides comprehensive protection for the Hospital Management System while maintaining performance and cost efficiency. Regular monitoring and tuning ensure optimal security posture.
