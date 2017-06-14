import javaposse.jobdsl.dsl.DslScriptLoader
import javaposse.jobdsl.plugin.JenkinsJobManagement
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.impl.*
import hudson.model.*
import jenkins.model.*
import hudson.plugins.groovy.*

def jobScript = new File('/usr/share/jenkins/jenkins_pipeline.groovy')
def jobManagement = new JenkinsJobManagement(System.out, [:], new File('.'))

File mavenRepoIdFile = new File('/usr/share/jenkins/mavenRepoId')
File mavenRepoUserFile = new File('/usr/share/jenkins/mavenRepoUser')
File mavenRepoPassFile = new File('/usr/share/jenkins/mavenRepoPass')
String mavenRepoId = mavenRepoIdFile?.text ?: "artifactory-local"
String mavenRepoUser = mavenRepoUserFile?.text ?: "admin"
String mavenRepoPass = mavenRepoPassFile?.text ?: "password"

println "Creating the settings.xml file"
String m2Home = '/var/jenkins_home/.m2'
boolean m2Created = new File(m2Home).mkdirs()
if (m2Created) {
	boolean settingsCreated = new File("${m2Home}/settings.xml").createNewFile()
	if (settingsCreated) {
		String settingsText = new File('/usr/share/jenkins/settings.xml').text
		settingsText = settingsText
				.replace('${M2_SETTINGS_REPO_ID}', mavenRepoId)
				.replace('${M2_SETTINGS_REPO_USERNAME}', mavenRepoUser)
				.replace('${M2_SETTINGS_REPO_PASSWORD}', mavenRepoPass)
		new File("${m2Home}/settings.xml").text = settingsText
	} else {
		println "Failed to create settings.xml!"
	}
} else {
	println "Failed to create .m2 folder!"
}

println "Creating the gradle.properties file"
String gradleHome = '/var/jenkins_home/.gradle'
boolean gradleCreated = new File(gradleHome).mkdirs()
if (gradleCreated) {
	boolean settingsCreated = new File("${gradleHome}/gradle.properties").createNewFile()
	if (settingsCreated) {
		String settingsText = new File('/usr/share/jenkins/gradle.properties').text
		settingsText = settingsText
				.replace('${M2_SETTINGS_REPO_USERNAME}', mavenRepoUser)
				.replace('${M2_SETTINGS_REPO_PASSWORD}', mavenRepoPass)
		new File("${gradleHome}/gradle.properties").text = settingsText
	}  else {
		println "Failed to create gradle.properties!"
	}
}  else {
	println "Failed to create .gradle folder!"
}

mavenRepoIdFile?.delete()
mavenRepoUserFile?.delete()
mavenRepoPassFile?.delete()

println "Creating the seed job"
new DslScriptLoader(jobManagement).with {
	runScript(jobScript.text
			.replace('https://github.com/marcingrzejszczak', "https://github.com/${System.getenv('FORKED_ORG')}")
			.replace('http://artifactory', "http://${System.getenv('EXTERNAL_IP') ?: "localhost"}"))
}

println "Creating the credentials"
['cf-test', 'cf-stage', 'cf-prod'].each { String id ->
	boolean credsMissing = SystemCredentialsProvider.getInstance().getCredentials().findAll {
		it.getDescriptor().getId() == id
	}.empty
	if (credsMissing) {
		println "Credential [${id}] is missing - will create it"
		SystemCredentialsProvider.getInstance().getCredentials().add(
				new UsernamePasswordCredentialsImpl(CredentialsScope.GLOBAL, id,
						"CF credential [$id]", "user", "pass"))
		SystemCredentialsProvider.getInstance().save()
	}
}


println "Importing GPG Keys"
def privateKey = new File('/usr/share/jenkins/private.key')
def publicKey = new File('/usr/share/jenkins/public.key')

void importGpgKey(String path) {
	def sout = new StringBuilder(), serr = new StringBuilder()
	String command = "gpg --import " + path
	def proc = command.execute()
	proc.consumeProcessOutput(sout, serr)
	proc.waitForOrKill(1000)
	println "out> $sout err> $serr"
}

if (privateKey.exists()) {
	println "Importing private key from " + privateKey.getPath()
	importGpgKey(privateKey.getPath())
	privateKey.delete()
} else {
	println "Private key file does not exist in " + privateKey.getPath()
}

if (publicKey.exists()) {
	println "Importing public key from " + publicKey.getPath()
	importGpgKey(publicKey.getPath())
	publicKey.delete()
} else {
	println "Public key file does not exist in " + publicKey.getPath()
}

File gitUserFile = new File('/usr/share/jenkins/gituser')
File gitPassFile = new File('/usr/share/jenkins/gitpass')
String gitUser = gitUserFile?.text ?: "changeme"
String gitPass = gitPassFile?.text ?: "changeme"

boolean gitCredsMissing = SystemCredentialsProvider.getInstance().getCredentials().findAll {
	it.getDescriptor().getId() == 'git'
}.empty

if (gitCredsMissing) {
	println "Credential [git] is missing - will create it"
	SystemCredentialsProvider.getInstance().getCredentials().add(
			new UsernamePasswordCredentialsImpl(CredentialsScope.GLOBAL, 'git',
					"GIT credential", gitUser, gitPass))
	SystemCredentialsProvider.getInstance().save()
}

gitUserFile?.delete()
gitPassFile?.delete()

println "Adding jdk"
Jenkins.getInstance().getJDKs().add(new JDK("jdk8", "/usr/lib/jvm/java-8-openjdk-amd64"))

println "Marking allow macro token"
Groovy.DescriptorImpl descriptor =
		(Groovy.DescriptorImpl) Jenkins.getInstance().getDescriptorOrDie(Groovy)
descriptor.configure(null, net.sf.json.JSONObject.fromObject('''{"allowMacro":"true"}'''))