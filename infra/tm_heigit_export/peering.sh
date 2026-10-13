#!/usr/bin/env bash
# Peers the Windmill EKS VPC with the TM VPC so workers can reach Aurora on 5432.
# Run: bash infra/tm_heigit_export/peering.sh
# Used by: hot-staff/f/shared/tm_heigit_export.py (see README.md here)
# Run once only: re-running creates a second peering.
set -euo pipefail

EKS_VPC=vpc-0f2142888a4f3c3c8 # VPC of the Windmill EKS cluster
TM_VPC=vpc-0622d8fdc96a1e44d # VPC of the TM Aurora cluster
AURORA_SG=sg-0d2792bbed0ee3e75 # Aurora cluster security group

a() { aws --profile admin --region us-east-1 "$@"; }

EKS_CIDR=$(a ec2 describe-vpcs --vpc-ids "$EKS_VPC" --query 'Vpcs[0].CidrBlock' --output text)
TM_CIDR=$(a ec2 describe-vpcs --vpc-ids "$TM_VPC" --query 'Vpcs[0].CidrBlock' --output text)
echo "EKS $EKS_VPC $EKS_CIDR  <->  TM $TM_VPC $TM_CIDR"
python3 -c "import ipaddress,sys; a,b=map(ipaddress.ip_network,sys.argv[1:]); sys.exit('CIDRs overlap, peering not possible' if a.overlaps(b) else 0)" "$EKS_CIDR" "$TM_CIDR"

echo "1. Create + accept peering"
PCX=$(a ec2 create-vpc-peering-connection --vpc-id "$EKS_VPC" --peer-vpc-id "$TM_VPC" \
  --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=windmill-to-tm},{Key=project,Value=tasking-manager},{Key=tool,Value=heigit-export}]' \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)
a ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids "$PCX"
a ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$PCX" >/dev/null
echo "   $PCX"

echo "2. Routes (every route table in each VPC -> the other VPC; routes cannot be tagged)"
for rt in $(a ec2 describe-route-tables --filters Name=vpc-id,Values="$EKS_VPC" --query 'RouteTables[].RouteTableId' --output text); do
  a ec2 create-route --route-table-id "$rt" --destination-cidr-block "$TM_CIDR" --vpc-peering-connection-id "$PCX" >/dev/null && echo "   $rt -> $TM_CIDR"
done
for rt in $(a ec2 describe-route-tables --filters Name=vpc-id,Values="$TM_VPC" --query 'RouteTables[].RouteTableId' --output text); do
  a ec2 create-route --route-table-id "$rt" --destination-cidr-block "$EKS_CIDR" --vpc-peering-connection-id "$PCX" >/dev/null && echo "   $rt -> $EKS_CIDR"
done

echo "3. Allow 5432 from EKS VPC on Aurora security group"
a ec2 authorize-security-group-ingress --group-id "$AURORA_SG" \
  --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=$EKS_CIDR,Description=windmill-eks heigit-export}]" \
  --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=windmill-eks},{Key=project,Value=tasking-manager},{Key=tool,Value=heigit-export}]' >/dev/null

echo "Done: $PCX"
echo "Undo: delete the routes above, revoke the SG rule, then"
echo "  aws --profile admin --region us-east-1 ec2 delete-vpc-peering-connection --vpc-peering-connection-id $PCX"
