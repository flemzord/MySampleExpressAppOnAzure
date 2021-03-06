workflow "Continuous Integration" {
  on = "push"
  resolves = [
    "Test",
  ]
}

action "Install" {
  uses = "actions/npm@master"
  args = "install"
}

action "Test" {
  uses = "actions/npm@master"
  needs = ["Install"]
  args = "test"
}

workflow "Documentation" {
  on = "push"
  resolves = [
    "Generate doc",
  ]
}

action "Filter for Doc generation" {
  uses = "actions/bin/filter@master"
  args = "branch master"
}

action "Generate doc" {
  uses = "helaili/jekyll-action@master"
  needs = ["Filter for Doc generation"]
  secrets = ["JEKYLL_PAT"]
}

workflow "Deploy to Test" {
  on = "deployment"
  resolves = ["Update deployment status"]
}

action "Env is Test" {
  uses = "actions/bin/filter@master"
  args = "environment test"
}

action "Azure Login" {
  uses = "Azure/github-actions/login@master"
  needs = ["Env is Test"]
  env = {
    AZURE_SUBSCRIPTION = "PAYG - GitHub Billing"
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
  }
  args = "--name ${DOCKER_REGISTRY_URL}"
  secrets = ["AZURE_SERVICE_APP_ID", "AZURE_SERVICE_PASSWORD", "AZURE_SERVICE_TENANT"]
}

action "Azure Registry Login" {
  uses = "actions/docker/login@master"
  needs = ["Env is Test"]
  env = {
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
  }
  secrets = [
    "DOCKER_PASSWORD",
    "DOCKER_USERNAME",
  ]
}

action "Build Docker Image" {
  uses = "actions/docker/cli@master"
  needs = ["Env is Test"]
  env = {
    WEBAPP_NAME = "mysampleexpressapp-actions"
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
  }
  args = "build -t ${DOCKER_REGISTRY_URL}/${WEBAPP_NAME}/${GITHUB_REF:11}:${GITHUB_SHA:0:7} ."
}

action "Push Docker Image" {
  uses = "actions/docker/cli@8cdf801b322af5f369e00d85e9cf3a7122f49108"
  needs = ["Build Docker Image", "Azure Registry Login"]
  env = {
    WEBAPP_NAME = "mysampleexpressapp-actions"
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
  }
  args = "push ${DOCKER_REGISTRY_URL}/${WEBAPP_NAME}/${GITHUB_REF:11}:${GITHUB_SHA:0:7}"
}

action "Create Azure WebApp" {
  uses = "Azure/github-actions/cli@master"
  needs = ["Azure Login"]
  env = {
    RESOURCE_GROUP = "github-octodemo"
    APP_SERVICE_PLAN = "github-octodemo-app-service-plan"
    WEBAPP_NAME = "mysampleexpressapp-actions"
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
    AZURE_SCRIPT = "az webapp create --resource-group $RESOURCE_GROUP --plan $APP_SERVICE_PLAN --name $WEBAPP_NAME-${GITHUB_SHA:0:7} --deployment-container-image-name ${DOCKER_REGISTRY_URL}/${WEBAPP_NAME}/${GITHUB_REF:11}:${GITHUB_SHA:0:7} --output json > $HOME/azure_webapp_creation.json"
  }
}

action "Deploy to Azure WebappContainer" {
  uses = "Azure/github-actions/cli@master"
  secrets = [
    "DOCKER_PASSWORD",
    "DOCKER_USERNAME",
    "AZURE_SUBSCRIPTION_ID",
  ]
  needs = ["Create Azure WebApp", "Push Docker Image"]
  env = {
    RESOURCE_GROUP = "github-octodemo"
    WEBAPP_NAME = "mysampleexpressapp-actions"
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
    AZURE_SCRIPT = "az webapp config container set --docker-custom-image-name ${DOCKER_REGISTRY_URL}/${WEBAPP_NAME}/${GITHUB_REF:11}:${GITHUB_SHA:0:7} --docker-registry-server-url $DOCKER_REGISTRY_URL --docker-registry-server-password $DOCKER_PASSWORD --docker-registry-server-user $DOCKER_USERNAME --name $WEBAPP_NAME-${GITHUB_SHA:0:7} --resource-group $RESOURCE_GROUP --subscription $AZURE_SUBSCRIPTION_ID"
  }
}

action "Set Webapp Tags" {
  uses = "Azure/github-actions/cli@master"
  secrets = [
    "AZURE_SUBSCRIPTION_ID",
  ]
  needs = ["Create Azure WebApp"]
  env = {
    RESOURCE_GROUP = "github-octodemo"
    WEBAPP_NAME = "mysampleexpressapp-actions"
    AZURE_SCRIPT = "BRANCH=$(jq -r '.deployment.ref' $GITHUB_EVENT_PATH) && az webapp update -g $RESOURCE_GROUP -n $WEBAPP_NAME-${GITHUB_SHA:0:7} --set tags.branch=$BRANCH"
  }
}

action "Update deployment status" {
  uses = "./actions/DeployStatusUpdateAction"
  needs = ["Deploy to Azure WebappContainer", "Push Docker Image", "Set Webapp Tags"]
  secrets = ["GITHUB_TOKEN"]
  args = "jq -r '\"https://\\(.defaultHostName)\"' $HOME/azure_webapp_creation.json"
}

workflow "Clean up" {
  on = "pull_request"
  resolves = [
    "Delete Docker Repository",
    "Udpate Deployment Status",
  ]
}

action "Filter closed PRs" {
  uses = "actions/bin/filter@master"
  args = "action closed"
}

action "Azure Login for Cleanup" {
  uses = "Azure/github-actions/login@master"
  needs = ["Filter closed PRs"]
  env = {
    AZURE_SUBSCRIPTION = "PAYG - GitHub Billing"
  }
  secrets = [
    "AZURE_SERVICE_APP_ID",
    "AZURE_SERVICE_PASSWORD",
    "AZURE_SERVICE_TENANT",
  ]
  args = "--name octodemo.azurecr.io"
}

action "Get Webapp List" {
  uses = "Azure/github-actions/cli@master"
  secrets = [
    "AZURE_SUBSCRIPTION_ID",
  ]
  needs = ["Azure Login for Cleanup"]
  env = {
    RESOURCE_GROUP = "github-octodemo"
    AZURE_SCRIPT = "BRANCH=$(jq -r '.pull_request.head.ref' $GITHUB_EVENT_PATH) && echo $BRANCH && az webapp list --resource-group $RESOURCE_GROUP --query \"[?tags.branch=='$BRANCH']\" > $HOME/webapp-list.json"
  }
}

action "Test Webapp List empty" {
  uses = "actions/bin/sh@master"
  needs = ["Get Webapp List"]
  args = ["filesize=$(wc -c < $HOME/webapp-list.json); echo $filesize; if [ \"$filesize\" -eq 3 ]; then exit 78; else exit 0; fi"]
}

action "Delete Webapps" {
  uses = "Azure/github-actions/cli@master"
  secrets = [
    "AZURE_SUBSCRIPTION_ID",
  ]
  needs = ["Test Webapp List empty"]
  env = {
    RESOURCE_GROUP = "github-octodemo"
    AZURE_SCRIPT = "WEBAPP_ID_LIST=$(jq -j '.[].id+\" \"' $HOME/webapp-list.json) && az webapp delete --ids $WEBAPP_ID_LIST --keep-empty-plan"
  }
}

action "Azure Registry Login for Cleanup" {
  uses = "actions/docker/login@master"
  needs = ["Test Webapp List empty"]
  env = {
    DOCKER_REGISTRY_URL = "octodemo.azurecr.io"
  }
  secrets = [
    "DOCKER_PASSWORD",
    "DOCKER_USERNAME",
  ]
}

action "Delete Docker Repository" {
  uses = "Azure/github-actions/cli@master"
  needs = ["Delete Webapps", "Azure Registry Login for Cleanup"]
  env = {
    WEBAPP_NAME = "mysampleexpressapp-actions"
    AZURE_SCRIPT = "az acr repository delete --name octodemo --repository ${WEBAPP_NAME}/${GITHUB_REF:11} --yes"
  }
}

action "Get Deployments" {
  uses = "actions/bin/curl@master"
  needs = ["Test Webapp List empty"]
  secrets = ["GITHUB_TOKEN"]
  args = ["-v", "-H \"Authorization: token $GITHUB_TOKEN\"", "https://api.github.com/repos/$GITHUB_REPOSITORY/deployments?ref=$(echo $GITHUB_REF | cut -f3 -d\"/\")", "> $HOME/deployments.json"]
}

action "Udpate Deployment Status" {
  uses = "helaili/jq-action@master"
  secrets = ["GITHUB_TOKEN"]
  needs = ["Get Deployments"]
  args = ["-r .[].statuses_url $HOME/deployments.json | xargs -L1 -I'{}' curl -v -H \"Authorization: token $GITHUB_TOKEN\" -H \"Accept: application/vnd.github.ant-man-preview+json\" -d '{\"state\": \"inactive\"}' {}"]
}

action "debug" {
  uses = "actions/bin/debug@master"
}

workflow "New Sprint" {
  on = "milestone"
  resolves = ["debug milestone"]
}

action "debug milestone" {
  uses = "actions/bin/debug@master"
}

workflow "New workflow" {
  on = "issues"
  resolves = ["debug issue"]
}

action "debug issue" {
  uses = "actions/bin/debug@master"
}
