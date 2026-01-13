#!/usr/bin/env groovy
library 'status-jenkins-lib@v1.9.37'

pipeline {
  agent { label 'macos && aarch64 && nix' }

  options {
    timestamps()
    ansiColor('xterm')
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
    disableRestartFromStage()
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
    cleanup {
      cleanWs()
      dir(env.WORKSPACE_TMP) { deleteDir() }
    }
  }
}
