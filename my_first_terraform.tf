//loginin to my(developer's) IAM account; source = Vimla Daga sir taught in training

provider "aws" {
  region     = "ap-south-1"
  profile    = "myprofile"
}



//creating key pair; source = https://stackoverflow.com/questions/49743220/how-do-i-create-an-ssh-key-in-terraform/49792833

variable "key_name" {default="mykey1234"}

resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}



resource "aws_key_pair" "generated_key" {

depends_on = [
    tls_private_key.example,
  ]

  key_name   = var.key_name
  public_key = tls_private_key.example.public_key_openssh
}





//creating security group;  source = https://www.terraform.io/docs/providers/aws/r/security_group.html

resource "aws_security_group" "allow_tls" {
  name        = "allow_tls"
  description = "allow ssh port and http port"

  ingress {
    description = "allow ssh port 22"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "allow http port 80"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  } 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "allow_tls"
  }
}




//creating an EC2 instance and installing required for webserver setup; source = Vimla Daga sir taught in training

resource "aws_instance" "httpd_webservers_instance" {

depends_on = [
    aws_security_group.allow_tls,
    aws_key_pair.generated_key,
  ]

  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name      = var.key_name
  security_groups = ["${aws_security_group.allow_tls.name}"]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.example.private_key_pem
    host     = aws_instance.httpd_webservers_instance.public_ip
  }
  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }

  tags = {
    Name = "myhttpdserver"
  }
}






// creating ebs volume 
resource "aws_ebs_volume" "myEBS" {

  depends_on = [
    aws_instance.httpd_webservers_instance,
  ]

  availability_zone = aws_instance.httpd_webservers_instance.availability_zone
  size              = 1

  tags = {
    Name = "myEBS"
  }

}






//attaching ebs to current instance

resource "aws_volume_attachment" "attach_to_myEBS" {

depends_on = [
    aws_ebs_volume.myEBS,
  ]
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.myEBS.id
  instance_id = aws_instance.httpd_webservers_instance.id
  force_detach = true
}





//my GitHub repository - https://github.com/devwrat55/my_first_hosted_simple_website.git
//mounting the block storage to created EC2 instance and cloning GitHub repo for server

resource "null_resource" "mount_clone_github"  {

depends_on = [
    aws_volume_attachment.attach_to_myEBS,
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.example.private_key_pem
    host     = aws_instance.httpd_webservers_instance.public_ip
  }

provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4 /dev/xvdh",
      "sudo mount /dev/xvdh /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/devwrat55/my_first_hosted_simple_website.git /var/www/html/"
    ]
  }
}





//configuration of S3 bucket; source = https://www.terraform.io/docs/providers/aws/r/cloudfront_distribution.html

resource "aws_s3_bucket" "mys3bucket" {

depends_on = [
    null_resource.mount_clone_github,
  ]

bucket = "liveworldindicessoftware"
acl    = "public-read"
}




//file to upload in S3 bucket; source = https://www.terraform.io/docs/providers/aws/r/cloudfront_distribution.html
// source = https://github.com/terraform-providers/terraform-provider-aws/issues/3020


resource "aws_s3_bucket_object" "filetoupload" {

depends_on = [
    aws_s3_bucket.mys3bucket,
  ]
  for_each = fileset("./images", "**/*.jpg")

  bucket = aws_s3_bucket.mys3bucket.bucket
  key    = each.value
  source = "${"./images"}/${each.value}"
  acl    = "public-read"
}






//configuring cloud front; source = https://www.terraform.io/docs/providers/aws/r/cloudfront_distribution.html

locals {
  s3_origin_id = aws_s3_bucket.mys3bucket.id
}


resource "aws_cloudfront_distribution" "s3_distribution" {

  depends_on = [
      aws_s3_bucket_object.filetoupload,
    ]


  origin {
    domain_name = aws_s3_bucket.mys3bucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id
  }


  enabled             = true
  is_ipv6_enabled     = true

  default_cache_behavior {

    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400

  }


  # Cache behavior with precedence 0
  ordered_cache_behavior {

    path_pattern     = "/content/immutable/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }


    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
    compress               = true
    viewer_protocol_policy = "redirect-to-https"

  }



  # Cache behavior with precedence 1
  ordered_cache_behavior {
    
    path_pattern     = "/content/*"

    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id
    
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
    viewer_protocol_policy = "redirect-to-https"

  }



  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "blacklist"
      locations        = ["CA"]
    }
  }

  tags = {
    Environment = "production"
  }



  viewer_certificate {
    cloudfront_default_certificate = true
  }
  retain_on_delete = true
}



locals {
  domain = "http://${aws_cloudfront_distribution.s3_distribution.domain_name}"
}



//updating html code with s3 url; github
resource "null_resource" "update_html_code"  {
depends_on = [
    aws_cloudfront_distribution.s3_distribution,
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.example.private_key_pem
    host     = aws_instance.httpd_webservers_instance.public_ip
  }

  provisioner "remote-exec" {
    inline = [
    "sudo python /var/www/html/replace_urls.py ${local.domain}"
    ]
  }
}





// writing output file
resource "null_resource" "outputfile"  {
depends_on = [
    null_resource.update_html_code,
  ]
  provisioner "local-exec" {
      command = "echo ${aws_instance.httpd_webservers_instance.public_ip} >> output_ipaddress.txt"
  }
}
