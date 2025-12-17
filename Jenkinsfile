#!/usr/bin/env groovy
library 'status-jenkins-lib@v1.9.13'

pipeline {
  agent { label 'linux && x86_64 && nix-2.24' }

  options {
    disableConcurrentBuilds()
    /* manage how many builds we keep */
    buildDiscarder(logRotator(
      numToKeepStr: '20',
      daysToKeepStr: '30',
    ))
  }

  stages {
    stage('Build') {
      steps {
        script {
          nix.flake("default")
        }
      }
    }

    stage('Check') {
      steps {
        script {
          sh './result/bin/storage --version'
        }
      }
    }
  }

  post {
    cleanup { cleanWs() }
  }
}
