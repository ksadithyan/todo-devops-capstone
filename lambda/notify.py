import gzip, json, os, urllib.parse, boto3

s3 = boto3.client("s3")
ecr = boto3.client("ecr")
sns = boto3.client("sns")


def lambda_handler(event, context):
    # 1. Download & unzip the CloudTrail log file S3 just received
    bucket = event["Records"][0]["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(event["Records"][0]["s3"]["object"]["key"])
    zipped = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    log = json.loads(gzip.decompress(zipped))

    # 2. Loop through events inside the log and find ECR pushes ("PutImage")
    for item in log.get("Records", []):
        if item.get("errorCode") or item.get("eventSource") != "ecr.amazonaws.com" or item.get("eventName") != "PutImage":
            continue

        repo = item["requestParameters"]["repositoryName"]
        tag = item["requestParameters"].get("imageTag", "latest")

        # 3. Ask ECR for image size, push date, and scan report (1 API call!)
        img = ecr.describe_images(repositoryName=repo, imageIds=[{"imageTag": tag}])["imageDetails"][0]
        size_mb = round(img["imageSizeInBytes"] / (1024 * 1024), 2)
        pushed_at = str(img["imagePushedAt"])
        scan_status = img.get("imageScanStatus", {}).get("status", "PENDING")
        scan_counts = img.get("imageScanFindingsSummary", {}).get("findingSeverityCounts", {})

        # 4. Email the details via SNS
        body = (
            f"Repo: {repo}\n"
            f"Tag: {tag}\n"
            f"Size: {size_mb} MB\n"
            f"Date: {pushed_at}\n"
            f"Scan ({scan_status}): {scan_counts or 'No vulnerabilities found'}\n"
        )
        sns.publish(TopicArn=os.environ["SNS_TOPIC_ARN"], Subject=f"ECR Push: {repo}:{tag}", Message=body)

    return {"status": "ok"}
