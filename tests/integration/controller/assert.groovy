import com.cloudbees.plugins.credentials.CredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import hudson.init.InitMilestone
import java.util.jar.JarFile
import jenkins.branch.NoTriggerOrganizationFolderProperty
import jenkins.branch.OrganizationFolder
import jenkins.model.Jenkins
import org.jenkinsci.plugins.github_branch_source.GitHubAppCredentials
import org.jenkinsci.plugins.github_branch_source.GitHubSCMNavigator
import org.jenkinsci.plugins.workflow.libs.GlobalLibraries

def jenkins = Jenkins.get()
assert jenkins.initLevel == InitMilestone.COMPLETED
assert jenkins.pluginManager.failedPlugins.empty : jenkins.pluginManager.failedPlugins

// Check every baked dependency as well as each direct pin.
def baked = new File('/usr/share/jenkins/ref/plugins').listFiles().findAll {
    it.name.endsWith('.jpi') || it.name.endsWith('.hpi')
}
assert !baked.empty
def bakedVersions = [:]
baked.each { archive ->
    new JarFile(archive).withCloseable { jar ->
        def attributes = jar.manifest.mainAttributes
        def id = attributes.getValue('Short-Name')
        def version = attributes.getValue('Plugin-Version')
        bakedVersions[id] = version
        def plugin = jenkins.pluginManager.getPlugin(id)
        assert plugin != null : "Missing baked plugin: ${id}"
        assert plugin.active : "Inactive baked plugin: ${id}"
        assert plugin.version == version : "Wrong baked version: ${id}: ${plugin.version} != ${version}"
    }
}
// The image must contain exactly the lock: no missing and no extra plugin.
def locked = new File('/test/plugins.lock.txt').readLines().collect {
    it.replaceFirst(/#.*/, '').trim()
}.findAll { it }.collectEntries { entry ->
    def parts = entry.split(':', 2)
    assert parts.length == 2 : "Bad lock line: ${entry}"
    [(parts[0]): parts[1]]
}
assert !locked.isEmpty()
assert bakedVersions == locked : "Image differs from lock. Only in image: ${bakedVersions - locked}; only in lock: ${locked - bakedVersions}"
def pins = new File('/test/plugins.txt').readLines().collect {
    it.replaceFirst(/#.*/, '').trim()
}.findAll { it }
assert !pins.empty
pins.each { pin ->
    def parts = pin.split(':', 2)
    assert parts.length == 2
    assert jenkins.pluginManager.getPlugin(parts[0])?.version == parts[1] : "Wrong pin: ${pin}"
}
assert !new File(jenkins.rootDir, 'plugins/stale-controller-test.jpi').exists()
assert !new File(jenkins.rootDir, 'plugins/git/stale-test-marker').exists()

assert jenkins.securityRealm.class.name == 'hudson.security.HudsonPrivateSecurityRealm'
assert jenkins.authorizationStrategy.class.name == 'hudson.security.FullControlOnceLoggedInAuthorizationStrategy'
assert jenkins.clouds.any { it.class.name == 'org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud' }
def store = CredentialsProvider.lookupStores(jenkins).find {
    it.getCredentials(Domain.global()).any { credential -> credential.id == 'github-app' }
}
assert store != null
def credentials = store.getCredentials(Domain.global())
assert credentials.find { it.id == 'github-app' } instanceof GitHubAppCredentials
assert credentials.any { it.id == 'github-webhook-secret' }
def library = GlobalLibraries.get().libraries.find { it.name == 'controller-test-library' }
assert library != null
assert library.defaultVersion == 'main'
def folder = jenkins.getItem('controller-test-organization')
assert folder instanceof OrganizationFolder
def navigator = folder.navigators.find { it instanceof GitHubSCMNavigator }
assert navigator != null
assert navigator.repoOwner == 'controller-test-owner'
assert navigator.credentialsId == 'github-app'
assert navigator.traits.size() == 3
assert folder.projectFactories.size() == 1
assert folder.buildStrategies.size() == 2
def suppression = folder.properties.get(NoTriggerOrganizationFolderProperty)
assert suppression != null
assert suppression.getBranches() == '.*'
assert suppression.getStrategy().name() == 'INDEXING'
println 'Loaded plugin receipt (name:version):'
jenkins.pluginManager.plugins.toList().sort { it.shortName }.each {
    assert it.active : "Inactive loaded plugin: ${it.shortName}"
    println "${it.shortName}:${it.version}"
}
println 'CONTROLLER_IMAGE_TEST_OK'
