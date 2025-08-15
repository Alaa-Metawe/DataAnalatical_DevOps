# DataAnalatical_DevOps
## **Prerequisites**
Terraform and AWSCLI installed
---
## **Project Structure**
```
.
├── main.tf              
├── variables.tf         
├── output.tf           
├── backend.tf           
├── lambda.zip           
├── .github/
│   └── workflows/
│       └── ci.yml  
└── README.md            
```
---
```
#################### 2. **Set AWS credentials**#############
You can use:
```bash
aws configure
```
Or set environment variables:
```bash
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
export AWS_REGION=us-east-1
```
---
### 3. **Prepare the Lambda function**
Your Lambda handler should be in `handler.py` (or similar).
Example `handler.py`:
```python
import json
def handler(event, context):
   print("Received event:", json.dumps(event))
   return {"status": "processed"}
```
Package it:
```bash
zip lambda.zip handler.py
```
---
### 4. **Initialize Terraform**
```bash
terraform init
```
If using remote backend (S3 for state), make sure `backend.tf` is configured correctly.
---
### 5. **Format and validate Terraform**
```bash
terraform fmt -recursive
terraform validate
```
---
### 6. **Plan the changes**
```bash
terraform plan
```
---
### 7. **Apply the changes**
```bash
terraform apply
```
---
### 8. **Test the pipeline**
1. Publish a message to SNS:
  ```bash
  aws sns publish \
    --topic-arn $(terraform output -raw sns_topic_arn) \
    --message '{"id": "123", "payload": "test"}'
  ```
2. Check SQS for the message:
  ```bash
  aws sqs receive-message \
    --queue-url $(terraform output -raw sqs_queue_url)
  ```
---
########### **GitHub Actions CI**##############
The workflow in `.github/workflows/ci.yml` will:
1. Check Terraform formatting.
2. Validate syntax.
3. Run a Terraform plan.
---
###### **Cleanup**######
To remove all resources:
```bash
terraform destroy
