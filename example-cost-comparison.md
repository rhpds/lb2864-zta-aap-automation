# Certificate Expiry: Downtime Cost Analysis

> Comparing 6 hours of unresolved TLS certificate expiry (2:00 AM - 8:00 AM) against automated resolution with Event-Driven Ansible


|                          | Scenario A: Manual | Scenario B: EDA |
| ------------------------ | ------------------ | --------------- |
| **Downtime**             | 6 hours            | < 2 minutes     |
| **Revenue at Risk (6h)** | $9,000 - $60,000   | $0              |
| **Annual Uptime Impact** | 99.3% (SLA breach) | 99.99%+         |


---

## Incident Timeline Comparison

### Scenario A: No Automation (HIGH RISK)


| Time  | Event                                                                |
| ----- | -------------------------------------------------------------------- |
| 02:00 | TLS certificate expires. HTTPS returns `ERR_CERT_DATE_INVALID`       |
| 02:00 | All browsers block access. Revenue drops to zero.                    |
| 02:01 | Search crawlers flag site as insecure. SEO index paused.             |
| 03:00 | International customers (APAC business hours) see security warnings. |
| 05:00 | Social media complaints begin from global users.                     |
| 08:00 | Engineer arrives, diagnoses issue, begins manual renewal.            |
| 08:30 | Certificate renewed. Service restored after **6.5 hours**.           |


### Scenario B: Event-Driven Ansible (RESOLVED)


| Time  | Event                                                            |
| ----- | ---------------------------------------------------------------- |
| 02:00 | Certmonger detects certificate approaching expiry / expired.     |
| 02:00 | Alert fires to EDA webhook (`ansible.eda.webhook`, port 5000).   |
| 02:00 | EDA rulebook matches condition, triggers job template.           |
| 02:01 | AAP executes `ipa-getcert` renewal against IdM CA.               |
| 02:02 | New certificate deployed. Service restarted. HTTPS restored.     |
| 02:02 | Notification sent to team. **Zero customer impact.**             |
| 08:00 | Engineer reviews successful auto-remediation in morning standup. |


---

## Direct Revenue Impact (6-Hour Window: 2 AM - 8 AM)

Estimates based on industry benchmarks for content-selling platforms. Off-peak hours (2-8 AM local) still carry 15-30% of daily traffic due to global audiences.


| Business Size    | Annual Revenue | Hourly Rate (Avg) | Off-Peak Rate (20%) | 6-Hour Loss | Annual Risk (3 incidents) |
| ---------------- | -------------- | ----------------- | ------------------- | ----------- | ------------------------- |
| Small            | $500K          | $57/hr            | $11/hr              | $68         | $205                      |
| Mid-Market       | $5M            | $570/hr           | $114/hr             | $685        | $2,055                    |
| Growth Stage     | $20M           | $2,283/hr         | $457/hr             | $2,740      | $8,219                    |
| Enterprise       | $100M          | $11,416/hr        | $2,283/hr           | $13,699     | $41,096                   |
| Large Enterprise | $500M          | $57,078/hr        | $11,416/hr          | $68,493     | $205,479                  |


---

## Hidden and Indirect Costs (Often 3-5x Direct Revenue Loss)


| Cost Category             | Impact Description                                             | Estimated Multiplier               | Recovery Time      |
| ------------------------- | -------------------------------------------------------------- | ---------------------------------- | ------------------ |
| SEO Ranking Loss          | Google downgrades HTTPS ranking signal; crawlers index errors  | 1.5-3x monthly organic revenue     | 2-6 weeks          |
| Browser Security Warnings | Chrome/Firefox show full-page interstitial blocking all access | 100% traffic loss during outage    | Immediate on fix   |
| Customer Trust Erosion    | 30-50% of users who see security warnings never return         | 0.3-0.5x of affected session value | Permanent loss     |
| SLA Breach Penalties      | 99.9% uptime = max 8.76h/year; 6h consumes 68% of budget       | Contract-defined penalties         | Next billing cycle |
| Brand Reputation          | Social media amplification in other timezones (APAC/EMEA)      | Difficult to quantify              | Weeks to months    |
| Engineering Emergency     | Incident response, root cause analysis, post-mortem            | $500-$2,000 per incident           | 1-2 days           |
| API Consumer Impact       | Downstream systems relying on your API fail their SLAs         | Cascading liability                | Variable           |


### Total Business Impact (Mid-Market Example: $5M Annual Revenue)


| Cost Component   | Conservative | Likely      |
| ---------------- | ------------ | ----------- |
| Direct Revenue   | $685         | $685        |
| SEO Recovery     | $1,000       | $3,000      |
| Customer Churn   | $500         | $2,000      |
| SLA Penalties    | $2,000       | $5,000      |
| Engineering Cost | $500         | $1,500      |
| **Total Impact** | **$4,685**   | **$12,185** |


---

## EDA Resolution: Technical Flow

Based on the ZTA Workshop architecture using IdM CA, certmonger, and Event-Driven Ansible with AAP 2.6.


| Step | Component               | Action                                                       | Duration      |
| ---- | ----------------------- | ------------------------------------------------------------ | ------------- |
| 1    | Certmonger / Monitoring | Detects certificate expiry or approaching threshold          | < 1 second    |
| 2    | Webhook Alert           | Fires event to EDA controller (port 5000)                    | < 1 second    |
| 3    | EDA Rulebook            | Matches condition, triggers certificate renewal job template | < 5 seconds   |
| 4    | AAP Job Template        | Executes `ipa-getcert` request against IdM CA                | 30-60 seconds |
| 5    | IdM CA                  | Issues new certificate, certmonger deploys to cert_dir       | 10-20 seconds |
| 6    | Service Restart         | Application service reloads with new TLS certificate         | 5-15 seconds  |
| 7    | Validation              | Healthcheck confirms HTTPS is serving valid certificate      | 5 seconds     |
| 8    | Notification            | Team alerted of successful auto-remediation                  | < 1 second    |


**Total automated resolution time: under 2 minutes.** Zero human intervention required.

---

## ROI: Event-Driven Ansible Investment


| Metric                  | Value                             |
| ----------------------- | --------------------------------- |
| EDA Platform Cost       | $0 (included in AAP subscription) |
| Mean Time to Resolution | < 2 minutes                       |
| Achievable Uptime       | 99.99%+                           |


### Investment Required


| Item                         | One-Time Cost | Ongoing Cost     | Notes                                      |
| ---------------------------- | ------------- | ---------------- | ------------------------------------------ |
| AAP Subscription (incl. EDA) | —             | Existing license | EDA is included in AAP 2.5+                |
| Rulebook Development         | 2-4 hours     | —                | One-time setup per use case                |
| IdM CA Integration           | 4-8 hours     | —                | Already deployed in most RHEL environments |
| Monitoring Integration       | 2-4 hours     | —                | Splunk/Wazuh webhook configuration         |
| Testing and Validation       | 4 hours       | —                | End-to-end test of renewal flow            |


---

## Break-Even Analysis

### Without EDA (Annual Risk)


| Metric                                      | Value                                  |
| ------------------------------------------- | -------------------------------------- |
| Probability of cert-related outage per year | High (73% of orgs experienced in 2023) |
| Average incidents per year                  | 2-4                                    |
| Cost per incident (mid-market, all-in)      | $5,000 - $15,000                       |
| Annual exposure                             | $10,000 - $60,000                      |
| Annual SLA risk consumed                    | 12-24 hours of budget                  |


### With EDA (Annual Savings)


| Metric                         | Value                        |
| ------------------------------ | ---------------------------- |
| Setup investment (one-time)    | 16-24 engineering hours      |
| Incidents auto-resolved        | 100% of certificate events   |
| Revenue protected per incident | $685 - $68,493               |
| Annual savings (mid-market)    | $10,000 - $60,000            |
| **Break-even**                 | **First prevented incident** |


---

## Key Insight

> **The real cost is not the 6 hours.**
>
> The direct revenue loss from 2 AM to 8 AM (off-peak) may seem manageable. The real damage comes from SEO deranking (weeks to recover), permanent customer loss (30-50% of affected visitors), SLA budget consumption (68% of annual allowance in one incident), and the cascading trust impact on API consumers and partners.
>
> Event-Driven Ansible eliminates this entire risk category at effectively zero marginal cost above your existing AAP investment.

---

*Report generated April 2026. Revenue estimates based on Gartner IT Downtime Survey, Ponemon Institute Cost of Data Center Outages, and KeyFactor 2023 Machine Identity Report (73% of organizations experienced certificate-related outages). Off-peak multiplier based on typical global content platform traffic distribution analysis. EDA resolution timeline based on ZTA Workshop architecture: IdM CA + certmonger + ansible.eda.webhook + AAP 2.6 job templates.*
