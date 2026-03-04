output "github_actions_role_arn"   { value = aws_iam_role.github_actions.arn }
output "ec2_instance_profile_name" { value = aws_iam_instance_profile.ec2.name }
output "ec2_role_arn"              { value = aws_iam_role.ec2.arn }
