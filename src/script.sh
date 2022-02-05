#!/bin/bash

action=$1

function check_error() {
  EXIT_CODE=$1

  if [[ $EXIT_CODE != 0 ]]; then
    echo "Error!"
    echo "Check error.log file"
    exit
  fi
}

function cleanup() {
  source env.txt

  ## Delete the listener
  if [[ -n "${AWS_ALB_LISTNER_ARN}" ]]; then
    echo -n "Delete the listener... "
    aws elbv2 delete-listener \
    --listener-arn $AWS_ALB_LISTNER_ARN

    check_error $?
    echo "Ok"
  fi

  ## Deregister targets
  if [[ -n "${AWS_ALB_TARGET_GROUP_ARN1}" ]] && [[ -n $AWS_CLUSTER_ONE_INSTANCES ]]; then
    echo -n "Deregister targets... "
    aws elbv2 deregister-targets \
    --target-group-arn $AWS_ALB_TARGET_GROUP_ARN1 \
    --targets "$(aws ec2 describe-instances \
                --query "Reservations[*].Instances[?contains('$AWS_CLUSTER_ONE_INSTANCES', InstanceId)].{Id: InstanceId}[]")"

    check_error $?
    echo -n "cluster1 done... "
  fi


  if [[ -n "${AWS_ALB_TARGET_GROUP_ARN2}" ]] && [[ -n $AWS_CLUSTER_TWO_INSTANCES ]]; then
    aws elbv2 deregister-targets \
    --target-group-arn $AWS_ALB_TARGET_GROUP_ARN2 \
    --targets "$(aws ec2 describe-instances \
                --query "Reservations[*].Instances[?contains('$AWS_CLUSTER_TWO_INSTANCES', InstanceId)].{Id: InstanceId}[]")"

    check_error $?
    echo "cluster2 Ok!"
  fi

  ## Delete target groups
  if [[ -n "${AWS_ALB_TARGET_GROUP_ARN1}" ]]; then
    echo -n "Delete target groups... "
    aws elbv2 delete-target-group \
    --target-group-arn $AWS_ALB_TARGET_GROUP_ARN1

    check_error $?
    echo "Ok"
  fi

  if [[ -n "${AWS_ALB_TARGET_GROUP_ARN2}" ]]; then
    aws elbv2 delete-target-group \
    --target-group-arn $AWS_ALB_TARGET_GROUP_ARN2

    check_error $?
    echo "Ok"
  fi

  ## Delete Application Load Balancer
  if [[ -n "${AWS_ALB_ARN}" ]]; then
    echo -n "Delete Application Load Balancer... "
    aws elbv2 delete-load-balancer \
    --load-balancer-arn $AWS_ALB_ARN

    check_error $?
    echo "Ok"
  fi

  ## Terminate the ec2 instances
  if [[ -n "${AWS_CLUSTER_ONE_INSTANCES}" ]]; then
    echo "Terminate the ec2 instances... Ok"
    aws ec2 wait instance-running --instance-ids ${AWS_CLUSTER_ONE_INSTANCES[@]} ${AWS_CLUSTER_TWO_INSTANCES[@]}

    check_error $?
    
    aws ec2 terminate-instances --instance-ids ${AWS_CLUSTER_ONE_INSTANCES[@]} ${AWS_CLUSTER_TWO_INSTANCES[@]} &> /dev/null

    check_error $?
    
    ## Wait for instances to enter 'terminated' state
    echo -n "Wait for instances to enter 'terminated' state... "
    aws ec2 wait instance-terminated --instance-ids ${AWS_CLUSTER_ONE_INSTANCES[@]} ${AWS_CLUSTER_TWO_INSTANCES[@]}

    check_error $?
    echo "Ok"
  fi

  ## Delete key pair
  echo -n "Delete key pair... "
  aws ec2 delete-key-pair \
  --key-name keypair

  check_error $?
  
  rm -f keypair.pem

  check_error $?
  echo "Ok"

  ## Delete custom security group (once instances are terminated)
  if [[ -n "$AWS_CUSTOM_SECURITY_GROUP_ID" ]]; then
    echo -n "Delete custom security group... "
    aws ec2 delete-security-group \
    --group-id $AWS_CUSTOM_SECURITY_GROUP_ID

    check_error $?
    echo "Ok"
  fi

  rm env.txt error.log
}


function deploy() {

  if [[ -f env.txt ]]; then
    echo "Previous deployement exists. Cleaning up..."
    sleep 1

    cleanup
    echo "Done! Beginning deployment..."
    sleep 1
  fi

  echo -n "Create a security group... "

  ## Create a security group
  aws ec2 create-security-group \
  --group-name vpc-security-group \
  --description 'VPC non default security group' > /dev/null \
  2> error.log

  check_error $?

  ## Get security group ID's
  AWS_CUSTOM_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --query 'SecurityGroups[?GroupName == `vpc-security-group`].GroupId' \
  --output text)
  check_error $?

  echo "AWS_CUSTOM_SECURITY_GROUP_ID=\"$AWS_CUSTOM_SECURITY_GROUP_ID\"" >> env.txt

  ## Create security group ingress rules
  aws ec2 authorize-security-group-ingress \
  --group-id $AWS_CUSTOM_SECURITY_GROUP_ID \
  --ip-permissions '[{"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "Allow SSH"}]}]' > /dev/null \
  2> error.log

  check_error $?

  aws ec2 authorize-security-group-ingress \
  --group-id $AWS_CUSTOM_SECURITY_GROUP_ID \
  --ip-permissions '[{"IpProtocol": "tcp", "FromPort": 8080, "ToPort": 8080, "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "Allow HTTP"}]}]' > /dev/null \
  2> error.log

  aws ec2 authorize-security-group-ingress \
  --group-id $AWS_CUSTOM_SECURITY_GROUP_ID \
  --ip-permissions '[{"IpProtocol": "tcp", "FromPort": 80, "ToPort": 8080, "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "Allow HTTP"}]}]' > /dev/null \
  2> error.log

  check_error $?

  echo "Success!"

  echo -n "Create a key-pair... "

  ## Create a key-pair
  aws ec2 create-key-pair \
  --key-name keypair \
  --query 'KeyMaterial' \
  --output text > keypair.pem \
  2> error.log

  check_error $?

  ## Change access to key pair to make it secure
  chmod 400 keypair.pem

  echo "Success!"

  echo -n "Create EC2 instances... "
  AWS_SUBNETS_1=$(aws ec2 describe-subnets --query "Subnets[0].SubnetId" --output text)
  AWS_SUBNETS_2=$(aws ec2 describe-subnets --query "Subnets[1].SubnetId" --output text)
  AWS_SUBNETS_3=$(aws ec2 describe-subnets --query "Subnets[2].SubnetId" --output text)
  AWS_SUBNETS_4=$(aws ec2 describe-subnets --query "Subnets[3].SubnetId" --output text)
  # AWS_SUBNETS_5=$(aws ec2 describe-subnets --query "Subnets[3].SubnetId" --output text)

  declare -a AWS_SUBNET_array
  AWS_SUBNET_array=($AWS_SUBNETS_1 $AWS_SUBNETS_2 $AWS_SUBNETS_3 $AWS_SUBNETS_4)
  ## Create EC2 instances
  AWS_CLUSTER_ONE_INSTANCES=()
  AWS_CLUSTER_TWO_INSTANCES=()

  for subnet in ${AWS_SUBNET_array[@]}
  do
  AWS_CLUSTER_ONE_INSTANCE=$(
      aws ec2 run-instances \
      --image-id ami-09e67e426f25ce0d7 \
      --instance-type t2.xlarge \
      --count 1 \
      --subnet-id $subnet\
      --key-name keypair \
      --monitoring "Enabled=true" \
      --security-group-ids $AWS_CUSTOM_SECURITY_GROUP_ID \
      --user-data file://instance.txt \
      --query 'Instances[*].InstanceId[]' \
      --output text
      )
  AWS_CLUSTER_TWO_INSTANCE=$(

      aws ec2 run-instances \
      --image-id ami-09e67e426f25ce0d7 \
      --instance-type m4.large \
      --count 1 \
      --subnet-id $subnet\
      --key-name keypair \
      --monitoring "Enabled=true" \
      --security-group-ids $AWS_CUSTOM_SECURITY_GROUP_ID \
      --user-data file://instance.txt \
      --query 'Instances[*].InstanceId[]' \
      --output text)
  AWS_CLUSTER_ONE_INSTANCES+=("$AWS_CLUSTER_ONE_INSTANCE")
  AWS_CLUSTER_TWO_INSTANCES+=("$AWS_CLUSTER_TWO_INSTANCE")

  done

  check_error $?
  echo "AWS_CLUSTER_ONE_INSTANCES=\"${AWS_CLUSTER_ONE_INSTANCES[@]}\"" >> env.txt

  check_error $?

  echo "AWS_CLUSTER_TWO_INSTANCES=\"${AWS_CLUSTER_TWO_INSTANCES[@]}\"" >> env.txt

  echo "Success!"

  echo -n "Create an application load balancer... "

  AWS_SUBNETS=$(aws ec2 describe-subnets --query 'Subnets[*].SubnetId' --output text)

  ## Create the application load balancer
  AWS_ALB_ARN=$(aws elbv2 create-load-balancer \
  --name application-load-balancer  \
  --subnets $AWS_SUBNETS \
  --security-groups $AWS_CUSTOM_SECURITY_GROUP_ID \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
  check_error $?

  echo "AWS_ALB_ARN=\"$AWS_ALB_ARN\"" >> env.txt

  AWS_VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`true`].VpcId' --output text)

  ## Create the target groups for your ALB
  AWS_ALB_TARGET_GROUP_ARN1=$(aws elbv2 create-target-group \
  --name cluster1 \
  --protocol HTTP --port 8080 \
  --vpc-id $AWS_VPC_ID \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
  check_error $?

  echo "AWS_ALB_TARGET_GROUP_ARN1=\"$AWS_ALB_TARGET_GROUP_ARN1\"" >> env.txt

  AWS_ALB_TARGET_GROUP_ARN2=$(aws elbv2 create-target-group \
  --name cluster2 \
  --protocol HTTP --port 8080 \
  --vpc-id $AWS_VPC_ID \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
  check_error $?

  echo "AWS_ALB_TARGET_GROUP_ARN2=\"$AWS_ALB_TARGET_GROUP_ARN2\"" >> env.txt

  echo "Success!"

  echo -n "Wait for instances to enter 'running' state... "

  aws ec2 wait instance-running --instance-ids ${AWS_CLUSTER_ONE_INSTANCES[@]} ${AWS_CLUSTER_TWO_INSTANCES[@]} \
  2> error.log

  check_error $?

  echo "Ready!"

  echo -n "Register the instances in the target groups... "

  ## Register the instances in the target groups
  for id_1 in ${AWS_CLUSTER_ONE_INSTANCES[@]}
  do
  aws elbv2 register-targets --target-group-arn $AWS_ALB_TARGET_GROUP_ARN1 \
  --targets Id=$id_1 \
    2> error.log
  check_error $?
  done

  for id_2 in ${AWS_CLUSTER_TWO_INSTANCES[@]}
  do
  aws elbv2 register-targets --target-group-arn $AWS_ALB_TARGET_GROUP_ARN2 \
  --targets Id=$id_2 \
  2> error.log
  check_error $?
  done

  echo "Success!"

  echo -n "Create path rules for alb listener... "

  ## Create a listener for your load balancer with a default rule that forwards requests to your target group
  AWS_ALB_LISTNER_ARN=$(aws elbv2 create-listener --load-balancer-arn $AWS_ALB_ARN \
  --protocol HTTP --port 80  \
  --default-actions \
  "[
    {
      \"Type\": \"forward\",
      \"ForwardConfig\": {
        \"TargetGroups\": [
          {
            \"TargetGroupArn\": \"$AWS_ALB_TARGET_GROUP_ARN1\",
            \"Weight\": 500
          },
          {
            \"TargetGroupArn\": \"$AWS_ALB_TARGET_GROUP_ARN2\",
            \"Weight\": 500
          }
        ]
      }
    }
  ]" \
  --query 'Listeners[0].ListenerArn' \
  --output text)
  check_error $?

  echo "AWS_ALB_LISTNER_ARN=\"$AWS_ALB_LISTNER_ARN\"" >> env.txt

  ## Create a rule using a path condition and a forward action for cluster 1
  aws elbv2 create-rule \
  --listener-arn $AWS_ALB_LISTNER_ARN \
  --priority 5 \
  --conditions file://conditions-cluster1.json \
  --actions Type=forward,TargetGroupArn=$AWS_ALB_TARGET_GROUP_ARN1 > /dev/null \
  2> error.log

  check_error $?

  ## Create a rule using a path condition and a forward action for cluster 2
  aws elbv2 create-rule \
  --listener-arn $AWS_ALB_LISTNER_ARN \
  --priority 6 \
  --conditions file://conditions-cluster2.json \
  --actions Type=forward,TargetGroupArn=$AWS_ALB_TARGET_GROUP_ARN2 > /dev/null \
  2> error.log

  check_error $?

  echo "Success!"

  echo -n "Wait for alb to become available and for instances to pass health checks..."

  aws elbv2 wait load-balancer-available --load-balancer-arns $AWS_ALB_ARN \
  2> error.log

  check_error $?

  aws elbv2 wait target-in-service --target-group-arn $AWS_ALB_TARGET_GROUP_ARN1 \
  --targets "$(aws ec2 describe-instances \
              --query "Reservations[*].Instances[?contains('$AWS_CLUSTER_ONE_INSTANCES', InstanceId)].{Id: InstanceId}[]")" \
  2> error.log

  check_error $?

  aws elbv2 wait target-in-service --target-group-arn $AWS_ALB_TARGET_GROUP_ARN2 \
  --targets "$(aws ec2 describe-instances \
  --query "Reservations[*].Instances[?contains('$AWS_CLUSTER_TWO_INSTANCES', InstanceId)].{Id: InstanceId}[]")" \
  2> error.log

  check_error $?

  AWS_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $AWS_ALB_ARN \
  --query 'LoadBalancers[0].DNSName' \
  --output text)
  echo "AWS_ALB_DNS=\"$AWS_ALB_DNS\"" >> env.txt

  echo "Ready!"
}

function benchmarking() {
  ## Once the ALB status is active, get the DNS name for your ALB
  source env.txt

  echo "###############################################"
  echo "#   Starting to send Get Request to clusters  #"
  echo "###############################################"

  python3 test_simple.py "http://$AWS_ALB_DNS/"

}
function visualization() {
  source env.txt



  echo "###################################################################################################"
  echo "#   Extracting Benchmarking Images from AWS: saving at app/static (Ignore invalid input message)  #"
  echo "###################################################################################################"

  #1-Healthy unhealthy count
  aws cloudwatch get-metric-widget-image --metric-widget '
  {
    "view": "timeSeries",
    "stacked": false,
    "metrics": [
        [ "AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", "LoadBalancer", "app/application-load-balancer/'"${AWS_ALB_ARN##*/}"'", "AvailabilityZone", "us-east-1e" ],
        [ "...", "us-east-1b" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "us-east-1c" ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", ".", ".", "us-east-1d" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "us-east-1e" ],
        [ "...", "us-east-1b" ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", ".", ".", "us-east-1c" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "us-east-1d" ]
    ],
    "width": 1619,
    "height": 250,
    "start": "-PT15M",
    "title": "Healthy Host Count",
    "end": "P0D"
  }' --output text | base64 -d >| app/static/healthy_count_.png

  #2-request count
  aws cloudwatch get-metric-widget-image --metric-widget '{
    "metrics": [
        [ "AWS/ApplicationELB", "RequestCount", "TargetGroup", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", "LoadBalancer", "app/application-load-balancer/'"${AWS_ALB_ARN##*/}"'", "AvailabilityZone", "us-east-1d" ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", ".", ".", "us-east-1c" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "." ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", ".", ".", "us-east-1d" ],
        [ "...", "us-east-1e" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "." ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", ".", ".", "us-east-1b" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "." ]
    ],
    "view": "timeSeries",
    "stacked": false,
    "title": "Request Count",
    "width": 1619,
    "height": 252,
    "start": "-PT15M",
    "end": "P0D"
  }' --output text | base64 -d >| app/static/request_count.png

#3-Target response time per AZ
  aws cloudwatch get-metric-widget-image --metric-widget '{
    "view": "timeSeries",
    "stacked": false,
    "metrics": [
        [ "AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", "app/application-load-balancer/'"${AWS_ALB_ARN##*/}"'", "AvailabilityZone", "us-east-1e" ],
        [ "...", "us-east-1c" ],
        [ "...", "us-east-1d" ],
        [ "...", "us-east-1b" ]
    ],
    "title": "Target Response Time per AZ",
    "width": 1619,
    "height": 250,
    "start": "-PT15M",
    "end": "P0D"
}' --output text | base64 -d >| app/static/target_response_time_AZ.png

#4-Target response time per TG
  aws cloudwatch get-metric-widget-image --metric-widget '{
    "view": "timeSeries",
    "stacked": false,
    "title": "Target Response Time per Target Group",
    "metrics": [
        [ "AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", "LoadBalancer", "app/application-load-balancer/'"${AWS_ALB_ARN##*/}"'" ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", "." ]
    ],
    "width": 1619,
    "height": 250,
    "start": "-PT15M",
    "end": "P0D"
}' --output text | base64 -d >| app/static/target_response_time_TG.png

aws cloudwatch get-metric-widget-image --metric-widget '{
    "view": "timeSeries",
    "stacked": false,
    "title": "Target Response Time per TG per AZ",
    "metrics": [
        [ "AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", "LoadBalancer", "app/application-load-balancer/'"${AWS_ALB_ARN##*/}"'", "AvailabilityZone", "us-east-1c" ],
        [ "...", "us-east-1d" ],
        [ "...", "us-east-1b" ],
        [ "...", "us-east-1e" ],
        [ "...", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", ".", ".", ".", "." ],
        [ "...", "us-east-1d" ],
        [ "...", "us-east-1c" ],
        [ "...", "us-east-1b" ]
    ],
    "width": 1619,
    "height": 251,
    "start": "-PT15M",
    "end": "P0D"
}' --output text | base64 -d >| app/static/target_response_time_TG_AZ.png

  #5-http Target 2xx
  aws cloudwatch get-metric-widget-image --metric-widget '{
    "view": "timeSeries",
    "stacked": false,
    "stat": "Average",
    "period": 300,
    "title": "HTTPCode Target 2XX",
    "setPeriodToTimeRange": true,
    "metrics": [
        [ "AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "TargetGroup", "targetgroup/cluster2/'"${AWS_ALB_TARGET_GROUP_ARN2##*/}"'", "LoadBalancer", "app/application-load-balancer/a566f55e5c3734d4", "AvailabilityZone", "us-east-1d" ],
        [ "...", "us-east-1b" ],
        [ "...", "us-east-1e" ],
        [ "...", "us-east-1c" ],
        [ "...", "targetgroup/cluster1/'"${AWS_ALB_TARGET_GROUP_ARN1##*/}"'", ".", ".", ".", "us-east-1e" ],
        [ "...", "us-east-1c" ],
        [ "...", "us-east-1d" ],
        [ "...", "us-east-1b" ]
    ],
    "width": 1619,
    "height": 250,
    "start": "-PT15M",
    "end": "P0D"
  }' --output text | base64 -d >| app/static/httpcode_target.png

  # #5-Request Count per Target
  # aws cloudwatch get-metric-widget-image --metric-widget '{
  #     "view": "timeSeries",
  #     "stacked": false,
  #     "title": "Request Count per Target",
  #     "metrics": [
  #         [ "AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", "targetgroup/cluster2/${AWS_ALB_TARGET_GROUP_ARN2##/*}", "LoadBalancer", "app/application-load-balancer/'"${AWS_ALB_ARN##*/}"'" ],
  #         [ "...", "targetgroup/cluster1/${AWS_ALB_TARGET_GROUP_ARN1##*/}", ".", "." ]
  #     ],
  #     "width": 1619,
  #     "height": 250,
  #     "start": "-PT15M",
  #     "end": "P0D"
  # }' --output text | base64 -d > app/static/request_per_target.png

  # #6-"HTTPCode Target 4XX
  # aws cloudwatch get-metric-widget-image --metric-widget '{
  #     "view": "timeSeries",
  #     "stacked": false,
  #     "title": "HTTPCode Target 4XX",
  #     "metrics": [
  #         [ "AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "TargetGroup", "targetgroup/cluster2/${AWS_ALB_TARGET_GROUP_ARN2##/*}", "LoadBalancer", "app/application-load-balancer/${AWS_ALB_ARN##*/}" ],
  #         [ "...", "targetgroup/cluster1/${AWS_ALB_TARGET_GROUP_ARN1##*/}", ".", "." ]
  #     ],
  #     "width": 1619,
  #     "height": 250,
  #     "start": "-PT15M",
  #     "end": "P0D"
  # }' --output text | base64 -d > app/static/httpcode_target4xx.png


  #7-cpuutilization of instance type

  aws cloudwatch get-metric-widget-image --metric-widget '{
      "view": "timeSeries",
      "stacked": false,
      "title": "CPU utilizations (%)",
      "metrics": [
          [ "AWS/EC2", "CPUUtilization", "InstanceType", "m4.large" ],
          [ "...", "t2.xlarge" ]
      ],
      "width": 1619,
      "height": 250,
      "start": "-PT15M",
      "end": "P0D"
  }' --output text | base64 -d >| app/static/cpuutilization.png

  #9-networkin of instance type

  aws cloudwatch get-metric-widget-image --metric-widget '{
      "view": "timeSeries",
      "stacked": false,
      "title": "Network In",
      "metrics": [
          [ "AWS/EC2", "NetworkIn", "InstanceType", "m4.large" ],
          [ "...", "t2.xlarge" ]
      ],
      "width": 1619,
      "height": 250,
      "start": "-PT15M",
      "end": "P0D"
  }' --output text | base64 -d >| app/static/networkin.png

  #10-cpu utilization  of Image

  aws cloudwatch get-metric-widget-image --metric-widget '{
      "view": "timeSeries",
      "stacked": false,
      "title": "CPU Utilization of Image",
      "metrics": [
          [ "AWS/EC2", "CPUUtilization", "ImageId", "ami-09e67e426f25ce0d7" ]
      ],
      "width": 1619,
      "height": 250,
      "start": "-PT15M",
      "end": "P0D"
  }' --output text | base64 -d >| app/static/cpu_image.png

  #8-networkin of Image
  aws cloudwatch get-metric-widget-image --metric-widget '{
      "view": "timeSeries",
      "stacked": false,
      "title": "Network In of Image",
      "metrics": [
          [ "AWS/EC2", "NetworkIn", "ImageId", "ami-09e67e426f25ce0d7" ]
      ],
      "width": 1619,
      "height": 250,
      "start": "-PT15M",
      "end": "P0D"
  }' --output text | base64 -d >| app/static/networkin_image.png
    echo "##############################################################################"
    echo "#                                                                            #"
    echo "#     Open localhost:5000 in your browser to see the benchmarking results    #"
    echo "#              Ctrl^C  to exit flask web application                         #"
    echo "##############################################################################"
  python3 run.py


    echo "##############################################################################"
    echo "#   Finished with benchmarking, Getting ready to delete ALB, TG, Instances...#"
    echo "##############################################################################"

}
print_help()
{
	printf '%s\n' "script's help msg"
	printf 'Usage: %s [--deploy] [--cleanup] [--benchmarking] [--complete]\n' "$0"
	printf '\t%s\n' "--deploy: Sets up AWS resources for ALB with 2 target groups"
	printf '\t%s\n' "--cleanup: Removes deployed AWS resources"
	printf '\t%s\n' "--benchmarking: Runs benchmarks on deployed AWS resources"
	printf '\t%s\n' "--complete: runs deploy, benchmarking and cleanup"
}


case "$action" in
  --deploy)
    deploy
    ;;
  --cleanup)
    cleanup
    ;;
  --benchmarking)
    benchmarking
    ;;
  --visualization)
    visualization
    ;;  
  --complete)
    deploy
    benchmarking
    visualization
    cleanup
    ;;
  ""|*)
    print_help
    ;;
esac