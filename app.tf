resource "google_iam_workload_identity_pool" "github_pool_demo" {
  provider = google-beta
  workload_identity_pool_id = "github-pool"
  display_name = "GitHub Pool"
}

resource "google_iam_workload_identity_pool_provider" "github_provider_demo" {
  provider = google-beta
  workload_identity_pool_id = google_iam_workload_identity_pool.github_pool_demo.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name = "GitHub Provider"
 
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.aud"        = "assertion.aud"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository_owner==\"backstage-dummy-org\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    allowed_audiences = ["https://iam.googleapis.com/projects/${var.project_id}/locations/global/workloadIdentityPools/github-pool/providers/github-provider"]
  }
}

resource "google_service_account" "github_actions" {
  project      = module.project-services.project_id
  account_id   = "genai-rag-run-sa-${random_id.id.hex}"
  display_name = "Service Account used for GitHub Actions"
}

resource "google_service_account" "terraform_sa" {
  project      = module.project-services.project_id
  account_id   = "genai-rag-run-sa-${random_id.id.hex}"
  display_name = "Terraform Service Account"
}

resource "google_service_account_iam_member" "sa_workload_identity_binding" {
  service_account_id = google_service_account.terraform_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${var.project_id}/locations/global/workloadIdentityPools/github-pool/attribute.repository/GenAI-RAG-Template"
}

# Applies permissions to the Cloud Run SA
resource "google_project_iam_member" "allrun" {
  for_each = toset([
    "roles/cloudsql.instanceUser",
    "roles/cloudsql.client",
    "roles/run.invoker",
    "roles/aiplatform.user",
    "roles/iam.serviceAccountTokenCreator",
  ])

  project = module.project-services.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Deploys a service to be used for the database
resource "google_cloud_run_v2_service" "retrieval_service" {
  name     = "retrieval-service-${random_id.id.hex}"
  location = var.region
  project  = module.project-services.project_id

  template {
    service_account = google_service_account.github_actions.email
    labels          = var.labels

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      image = var.retrieval_container
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
      env {
        name  = "APP_HOST"
        value = "0.0.0.0"
      }
      env {
        name  = "APP_PORT"
        value = "8080"
      }
      env {
        name  = "DB_KIND"
        value = "cloudsql-postgres"
      }
      env {
        name  = "DB_PROJECT"
        value = module.project-services.project_id
      }
      env {
        name  = "DB_REGION"
        value = var.region
      }
      env {
        name  = "DB_INSTANCE"
        value = google_sql_database_instance.main.name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.database.name
      }
      env {
        name  = "DB_USER"
        value = google_sql_user.service.name
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.cloud_sql_password.secret_id
            version = "latest"
          }
        }
      }
    }
  }
}

# Deploys a service to be used for the frontend
resource "google_cloud_run_v2_service" "frontend_service" {
  name     = "frontend-service-${random_id.id.hex}"
  location = var.region
  project  = module.project-services.project_id

  template {
    service_account = google_service_account.github_actions.email
    labels          = var.labels

    containers {
      image = var.frontend_container
      env {
        name  = "SERVICE_URL"
        value = google_cloud_run_v2_service.retrieval_service.uri
      }
      env {
        name  = "SERVICE_ACCOUNT_EMAIL"
        value = google_service_account.github_actions.email
      }
      env {
        name  = "ORCHESTRATION_TYPE"
        value = "langchain-tools"
      }
      env {
        name  = "DEBUG"
        value = "False"
      }
    }
  }
}

# Set the frontend service to allow all users
resource "google_cloud_run_service_iam_member" "noauth_frontend" {
  location = google_cloud_run_v2_service.frontend_service.location
  project  = google_cloud_run_v2_service.frontend_service.project
  service  = google_cloud_run_v2_service.frontend_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

data "google_service_account_id_token" "oidc" {
  target_audience = google_cloud_run_v2_service.retrieval_service.uri
}

# Trigger the database init step from the retrieval service
# Manual Run: curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" {run_service}/data/import

# tflint-ignore: terraform_unused_declarations
data "http" "database_init" {
  url    = "${google_cloud_run_v2_service.retrieval_service.uri}/data/import"
  method = "GET"
  request_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${data.google_service_account_id_token.oidc.id_token}"
  }

  depends_on = [
    google_sql_database.database,
    google_cloud_run_v2_service.retrieval_service,
    data.google_service_account_id_token.oidc,
  ]
}
