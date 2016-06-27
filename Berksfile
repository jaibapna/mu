if !ENV.include?('MU_LIBDIR')
	if !ENV.include?('MU_INSTALLDIR')
		raise "Can't find MU_LIBDIR or MU_INSTALLDIR in my environment!"
	end
	ENV['MU_LIBDIR'] = ENV['MU_INSTALLDIR']+"/lib"
end
cookbookPath = "#{ENV['MU_LIBDIR']}/cookbooks"
siteCookbookPath = "#{ENV['MU_LIBDIR']}/site_cookbooks"

source "https://supermarket.getchef.com"

cookbook 'aws', '~> 2.9.3'
cookbook 'awscli', path: "#{cookbookPath}/awscli"
cookbook 'chef-splunk', path: "#{cookbookPath}/chef-splunk"
cookbook 'demo', path: "#{siteCookbookPath}/demo"
cookbook 'ec2-s3-api-tools', path: "#{cookbookPath}/ec2-s3-api-tools"
cookbook 'freebsd', '~> 0.1.9'
cookbook 'gunicorn', '~> 1.1.2'
cookbook 'logrotate', '~> 1.9.2'
cookbook 'memcached', '~> 1.7.2'
cookbook 'mu-activedirectory', path: "#{cookbookPath}/mu-activedirectory"
cookbook 'mu-demo', path: "#{cookbookPath}/mu-demo"
cookbook 'mu-glusterfs', path: "#{cookbookPath}/mu-glusterfs"
cookbook 'mu-jenkins', path: "#{cookbookPath}/mu-jenkins"
cookbook 'mu-master', path: "#{cookbookPath}/mu-master"
cookbook 'mu-mongo', path: "#{cookbookPath}/mu-mongo"
cookbook 'mu-openvpn', path: "#{cookbookPath}/mu-openvpn"
cookbook 'mu-php54', path: "#{cookbookPath}/mu-php54"
cookbook 'mu-tools', path: "#{cookbookPath}/mu-tools"
cookbook 'mu-utility', path: "#{cookbookPath}/mu-utility"
cookbook 'mysql-chef_gem', path: "#{cookbookPath}/mysql-chef_gem"
cookbook 'nagios', path: "#{cookbookPath}/nagios"
cookbook 'nginx-passenger', path: "#{cookbookPath}/nginx-passenger"
cookbook 'pacman', '~> 1.1.1'
cookbook 'passenger_apache2', '~> 2.1.2'
cookbook 'python', path: "#{cookbookPath}/python"
cookbook 'ruby-cookbook', path: "#{cookbookPath}/ruby-cookbook"
cookbook 'rvm', path: "#{cookbookPath}/rvm"
cookbook 's3fs', path: "#{cookbookPath}/s3fs"
cookbook 'supervisor', '~> 0.4.12'
cookbook 'tar', '~> 0.7.0'
cookbook 'tomcat', path: "#{cookbookPath}/tomcat"
cookbook 'unicorn', '~> 1.3.0'
cookbook 'xfs', '~> 1.1.0'
cookbook 'zipfile', '~> 0.1.0'
