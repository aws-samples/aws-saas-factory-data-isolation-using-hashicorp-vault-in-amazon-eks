# SaaS Data Isolation with Dynamic Credentials Using HashiCorp Vault in Amazon EKS

The code shared here is intended to provide a sample implementation of SaaS Data Isolation with Dynamic Credentials Using HashiCorp Vault in Amazon EKS. The goal is to provide SaaS developers and architects with working code that will illustrate how multi-tenant SaaS applications can be design and delivered on AWS using Hashicorp Vault and Amazon EKS. The solution implements an identity model that simplifies the management of data access policies and credentials in isolated tenant environments. The focus here is more on giving developers a view into the working elements of the solution without going to the extent of making a full, production-ready solution.

Note that the instructions below are intended to give you step-by-step, how-to instructions for getting this solution up and running in your own AWS account.

## Setting up the environment

> :warning: The Cloud9 workspace should be built by an IAM user with Administrator privileges, not the root account user. Please ensure you are logged in as an IAM user, not the root account user.

1. Create new Cloud9 Environment
    * Launch Cloud9 in your closest region Ex: `https://us-west-2.console.aws.amazon.com/cloud9/home?region=us-west-2`
    * Select Create environment
    * Name it whatever you want, click Next.
    * Choose “t3.small” for instance type, take all default values and click Create environment
2. Create EC2 Instance Role
    * Follow this [deep link](https://console.aws.amazon.com/iam/home#/roles$new?step=review&commonUseCase=EC2%2BEC2&selectedUseCase=EC2&policies=arn:aws:iam::aws:policy%2FAdministratorAccess) to create an IAM role with Administrator access.
    * Confirm that AWS service and EC2 are selected, then click Next to view permissions.
    * Confirm that AdministratorAccess is checked, then click `Next: Tags` to assign tags.
    * Take the defaults, and click `Next: Review` to review.
    * Enter `dynamic-policy-ref-arch-admin` for the Name, and click `Create role`.
3. Remove managed credentials and attach EC2 Instance Role to Cloud9 Instance
    * Click the gear in the upper right-hand corner of the IDE which opens settings. Click the `AWS Settings` on the left and under `Credentials` slide the button to the left for `AWS managed temporary credentials`. The button should be greyed out when done, indicating it's off.
    * Click the round Button with an alphabet in the upper right-hand corner of the IDE and click `Manage EC2 Instance`. This will take you to the EC2 portion of the AWS Console
    * Right-click the EC2 instance and in the fly-out menu, click `Security` -> `Modify IAM Role`
    * Choose the Role you created in step 3 above. It should be titled `dynamic-policy-ref-arch-admin` and click `Save`.
4. Clone the repo and run the setup script
    * Return to the Cloud9 IDE
    * In the upper left part of the main screen, click the round green button with a `+` on it and click `New Terminal`
    * Enter the following in the terminal window

    ```bash
    git clone https://github.com/aws-samples/aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks.git
    cd aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks
    chmod +x setup.sh
    ./setup.sh
   ```

   This [script](./setup.sh) sets up Kubernetes tools, updates the AWS CLI and installs other dependencies that we'll use later. It also creates an S3 bucket for centrally managing the Vault Agent Templates, and creates the relevant IAM policy to allow the Vault Agent to read the templates and render secrets. Take note of the final output of this script. If everything worked correctly, you should see the message that the you're good to continue creating the EKS cluster. If you do not see this message, please do not continue. Ensure that the Administrator EC2 role was created and successfully attached to the EC2 instance that's running your Cloud9 IDE. Also ensure you turned off `AWS managed temporary credentials` inside your Cloud9 IDE (refer to steps 2 and 3).

5. Create the EKS Cluster
    * Edit the script `deploy-eks.sh` to specify a CIDR range for the EKS Cluster VPC
    * Make sure that the CIDR range does not overlap with any existing network segments and route table entries
    * This script will be adding a route in the route table associated with this Cloud9 Instance for the EKS Cluster private endpoints
    * Run the following script to create a cluster configuration file, and subsequently provision the cluster using `eksctl`:

    ```bash
    chmod +x deploy-eks.sh
    ./deploy-eks.sh
    ```

    The cluster will take approximately 30 minutes to deploy.
    
    This [script](./deploy-eks.sh) creates:
    
    a. An IAM Role for Service Account (IRSA) to provide S3 bucket access for the Vault Agent, with a trust policy based on the EKS Cluster's associated OIDC provider
    
    b. An IAM Role for Service Account (IRSA) to enable the Vault Server to call STS AssumeRole

6. Create and Populate DynamoDB Table
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    ```bash
    chmod +x create-dynamodb-table.sh
    ./create-dynamodb-table.sh
    ```

    This [script](./create-dynamodb-table.sh) completes the following steps:

    a. Creates DynamoDB table Products
    
    b. Populates the Products table with data used for testing the silo and pooled tenant isolation scenarios


7. Deploy Vault Engine
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    ```bash
    cd vault-engine
    chmod +x deploy-vault.sh
    ./deploy-vault.sh
    ```

    This [script](./vault-engine/deploy-vault.sh) completes the following steps:

    a. Creates Vault Role in IAM, with an STS AssumeRole trust policy
    
    b. Creates Vault DynamoDB policy in IAM

    c. Attaches the DynamoDB policy to Vault Role
    
    d. Creates an AssumeRole policy and attaches it to the Vault IRSA
    
    e. Creates Vault namespace in EKS Cluster
    
    f. Installs Vault Engine using Helm
    
    g. Stores the Vault Root Token and Unseal Keys as secrets in AWS Secrets Manager

    h. Initializes and unseals the Vault
    
    i. Enable AWS Secrets Engine & Approle Auth Method in Vault
    

8. Deploy Sample Silo Tenants
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    ```bash
    cd silo
    chmod +x deploy-siloed-tenants.sh
    ./deploy-siloed-tenants.sh
    ```

    This [script](./silo/deploy-siloed-tenants.sh) creates the following, for each tenant (tenanta & tenantb):

    a. Vault role along with the tenant-scoped IAM session policy
    
    b. Vault policy that allows access to tenant-scoped credentials
    
    c. Vault credentials access endpoint
    
    d. AppRole for the Vault Agent sidecar, bound to the tenant-specific Vault policy
    
    e. AppRole credentials (role_id / secret_id) for the Vault Agent sidecar

    f. Kubernetes namespace for the tenant
    
    g. Kubernetes secret containing the Vault Agent's AppRole credentials
    
    h. Kubernetes configmap containing the Vault Agent configuration

    i. Application pods


9. Test Silo Tenant Deployments
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    a. In the Cloud9 test editor, open [test-cases/shell-into-tenant-container.sh](./test-cases/shell-into-tenant-container.sh)
    
    b. Modify the value of environment variable APPLICATION_NS to "tenanta" or "tenantb"
    
    c. Select all the contents of test-cases/shell-into-tenant-container.sh
    
    d. Open a **_NEW_** terminal window
    
    e. Paste the contents of test-cases/shell-into-tenant-container.sh
    
    f. You would now be in a shell within the tenant-specific application (myapp) container
    
    g. In the Cloud9 test editor, open [test-cases/test-dynamodb-access.sh](./test-cases/test-dynamodb-access.sh)
    
    h. Modify the value of environment variable TENANT to "tenanta" or "tenantb", matching the APPLICATION_NS value set in step (b)
    
    i. Select all the contents of test-cases/test-dynamodb-access.sh
    
    j. Paste the contents into the shell that was started on the tenant-specific application container
    
    k. Data items will be pulled from the DynamoDB table Products only where the ShardID matches the tenant ID set by the environment variable AWS_PROFILE. AWS CLI uses the AWS credentials file to use the credentials for the tenant-specific profile.

    l. Data items where the ShardID doesn't match the tenant ID will not be retrieved and the following error will be generated.
    ```
    An error occurred (AccessDeniedException) when calling the GetItem operation: User: arn:aws:sts::ACCOUNT_ID:federated-user/vault-xxxxxxxxxx-yyyyyyyyyyyyyyy is not authorized to perform: dynamodb:GetItem on resource: arn:aws:dynamodb:AWS_REGION:ACCOUNT_ID:table/Products_xxxxxxxx because no session policy allows the dynamodb:GetItem action
    ```
10. Deploy Sample Pooled Tenants
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    ```bash
    cd pool
    chmod +x deploy-pooled-tenants.sh
    ./deploy-pooled-tenants.sh
    ```

    This [script](./pool/deploy-pooled-tenants.sh) creates the following, for each tenant (tenantc & tenantd):

    a. A Vault role with tenant-scoped IAM session policy
    
    b. Vault policy that allows access to credentials for all sub-tenant (tenantc-* / tenantd-*)
    
    c. A Vault credentials endpoint
    
    d. AppRole for the Vault Agent bound to the tenant-specific Vault policy
    
    e. AppRole credentials (role_id / secret_id) for the Vault Agent sidecar

    f. Kubernetes namespace for the tenant
    
    g. Kubernetes secret containing the Vault Agent's AppRole credentials
    
    h. Kubernetes configmap containing the Vault Agent configuration

    i. Application pods


11. Deploy Sample Pooled Sub-Tenants
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    ```bash
    cd pool
    chmod +x deploy-pool-sub-tenants.sh
    ./deploy-pool-sub-tenants.sh
    ```

    This [script](./pool/deploy-pool-sub-tenants.sh) completes the following, for each tenant (tenantc & tenantd):

    a. For each sub-tenant, creates a Vault role along with the sub-tenant-scoped IAM session policy
    
    b. For each sub-tenant, creates a Vault credentials endpoint
    
    c. Updates tenant-specific Vault Agent configmap with a template to generate sub-tenant credentials in the mapped secrets volume

    d. Restarts the Vault Agent process with a kill -SIGHUP, for the process to re-read the configmap


12. Test Pooled Tenant Deployments
    > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

    a. In the Cloud9 test editor, open [test-cases/shell-into-tenant-container.sh](./test-cases/shell-into-tenant-container.sh)
    
    b. Modify the value of environment variable APPLICATION_NS to "tenantc" or "tenantd"
    
    c. Select all the contents of test-cases/shell-into-tenant-container.sh
    
    d. Open a **_NEW_** terminal window
    
    e. Paste the contents of test-cases/shell-into-tenant-container.sh
    
    f. You would now be in a shell within the sub-tenant-specific application (myapp) container
    
    g. In the Cloud9 test editor, open [test-cases/test-dynamodb-access.sh](./test-cases/test-dynamodb-access.sh)
    
    h. Modify the value of environment variable TENANT to "tenantc-1", "tenantc-2", "tenantd-1", or "tenantd-2", corresponding to the APPLICATION_NS value set in step (b)
    
    i. Select all the contents of test-cases/test-dynamodb-access.sh
    
    j. Paste the contents into the shell that was started on the sub-tenant-specific application container
    
    k. Data items will be pulled from the DynamoDB table Products only where the ShardID matches the sub-tenant ID set by the environment variable AWS_PROFILE. AWS CLI uses the AWS credentials file to use the credentials for the sub-tenant-specific profile.

    l. Data items where the ShardID doesn't match the tenant ID will not be retrieved and the following error will be generated.
    ```
    An error occurred (AccessDeniedException) when calling the GetItem operation: User: arn:aws:sts::ACCOUNT_ID:federated-user/vault-xxxxxxxxxx-yyyyyyyyyyyyyyy is not authorized to perform: dynamodb:GetItem on resource: arn:aws:dynamodb:AWS_REGION:ACCOUNT_ID:table/Products_xxxxxxxx because no session policy allows the dynamodb:GetItem action
    ```


## Cleanup
   > :warning: Close the terminal window that you created the cluster in, and open a new terminal before starting this step otherwise you may get errors about your AWS_REGION not set.
    * Open a **_NEW_** terminal window and `cd` back into `aws-saas-factory-data-isolation-using-hashicorp-vault-in-amazon-eks` and run the following script:

1. The deployed components can be cleaned up by running the following:

    ```bash
    chmod +x cleanup.sh
    ./cleanup.sh
    ```

    This [script](./cleanup.sh) will 

    a. Delete Vault Root Token and Unseal Keys from Secrets Manager
    
    b. Uninstall Vault Engine
    
    c. Delete Vault Engine Namespace

    d. Delete the EKS Cluster

    e. Disable the KMS Master Key and removes the alias

    f. Delete EC2 Key-Pair
    
    g. Detach IAM policies from Vault User
    
    h. Delete Access Key for Vault User
    
    i. Delete Vault User in IAM
    
    j. Delete Vault STS Policy in IAM
    
    k. Delete Vault DynamoDB Policy in IAM

2. You can also delete

    a. The EC2 Instance Role `dynamic-policy-ref-arch-admin`

    b. The Cloud9 Environment

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

