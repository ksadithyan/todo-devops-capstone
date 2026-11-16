# 1. Generate a random DB password (no special chars that break shell/URLs)
resource "random_password" "db" {
  length  = 20
  special = false
}

# 2. Save DB password in AWS SSM Parameter Store (Standard SecureString = FREE)
resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project_name}/db/password"
  type  = "SecureString"
  value = random_password.db.result
}

# 3. DB Subnet Group across your 2 Private DB Subnets (AWS requires 2 AZs)
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private_db[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# 4. Security Group: allow MySQL port 3306 ONLY from EKS cluster/nodes
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow MySQL only from EKS nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from EKS"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
 # there is no need for egress. the SG is stateful so with just the ingress it allows the connection back

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# 5. Amazon RDS MySQL (lowest-cost db.t3.micro, private only, clean destroy)
resource "aws_db_instance" "main" {
  identifier             = "${var.project_name}-mysql"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  db_name                = "tododb_prod"
  username               = "todouser"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    Name = "${var.project_name}-mysql"
  }
}

# Save RDS host endpoint to SSM Parameter Store too
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/db/host"
  type  = "String"
  value = aws_db_instance.main.address
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_password_ssm_parameter" {
  value = aws_ssm_parameter.db_password.name
}
