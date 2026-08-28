pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "AnchoragePerimeter"

// One module. The architecture lives in the package structure under
// `com.anchorage.perimeter` (presentation / domain / data / core) and is
// enforced by ArchitectureTest rather than by Gradle module boundaries.
include(":app")
