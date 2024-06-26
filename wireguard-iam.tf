data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "wireguard_policy_doc" {
  statement {
    actions = [
      "ec2:AssociateAddress",
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "wireguard_read_private_key" {
  statement {
    actions = [
      "ssm:GetParameter"
    ]
    resources = [
      format("arn:aws:ssm:%s:%s:parameter%s",
        data.aws_region.current.name,
        data.aws_caller_identity.current.account_id,
        var.wg_server_private_key_param
      )
    ]
  }
}

resource "aws_iam_policy" "wireguard_eip_policy" {
  name        = "tf-wireguard-${var.env}-eip"
  description = "Terraform Managed. Allows Wireguard instance to attach EIP."
  policy      = data.aws_iam_policy_document.wireguard_policy_doc.json
  count       = (var.use_eip ? 1 : 0)
}

resource "aws_iam_policy" "wireguard_ssm_private_key_policy" {
  name        = "tf-wireguard-${var.env}-ssm-private-key"
  description = "Terraform Managed. Allows Wireguard instance to read SSM wireguard private key."
  policy      = data.aws_iam_policy_document.wireguard_read_private_key.json
}

resource "aws_iam_role" "wireguard_role" {
  name               = "tf-wireguard-${var.env}"
  description        = "Terraform Managed. Role with Wireguard instance permissions."
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "wireguard_roleattach" {
  role       = aws_iam_role.wireguard_role.name
  policy_arn = aws_iam_policy.wireguard_eip_policy[0].arn
  count      = (var.use_eip ? 1 : 0) # only used for EIP mode
}

resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.wireguard_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  count      = var.install_ssm ? 1 : 0
}

resource "aws_iam_role_policy_attachment" "ssm_private_key_policy_attachment" {
  role       = aws_iam_role.wireguard_role.name
  policy_arn = aws_iam_policy.wireguard_ssm_private_key_policy.arn
}

resource "aws_iam_instance_profile" "wireguard_profile" {
  name = "tf-wireguard-${var.env}"
  role = aws_iam_role.wireguard_role.name
}
