#!/usr/bin/env bash
set -x

rm ansible.cfg.j2
rm ssh-config.j2
rm ansible.cfg
rm ssh-config
rm cue-update-configure.yml
rm cue-install-packages.yml

cat > ansible.cfg.j2 << EOF
[defaults]
system_errors = False
host_key_checking = False
ask_sudo_pass = False
[ssh_connection]
ssh_args = -o ControlPersist=15m -o ConnectTimeout=120 -F {{ playbook_path_output.stdout }}/ssh-config -q
scp_if_ssh = True
ControlPath ~/.ssh/ansible-%r@%h:%p
EOF

cat > ssh-config.j2 << EOF
Host *
ServerAliveInterval 60
TCPKeepAlive yes
ProxyCommand ssh -q -A stack@{{ controller_node_ip }} nc %h %p
ControlMaster auto
ControlPath ~/.ssh/ansible-%r@%h:%p
ControlPersist 8h
User stack
IdentityFile /home/stack/.ssh/id_rsa
EOF

cat > cue-update-configure.yml << EOF
---
- hosts: localhost
  connection: local
  tasks:
    - name: cue-update-configure | Ensure OpenStack credentials are available
      fail: msg="Please ensure OpenStack credentials have been sourced"
      when: lookup('env', 'OS_AUTH_URL') == ""
    - name: cue-update-configure | Get working directory
      shell: pwd
      register: playbook_path_output
    - name: cue-update-configure | Create Ansible.cfg
      template:
        src: ansible.cfg.j2
        dest: "{{ playbook_path_output.stdout }}/ansible.cfg"
    - name: cue-update-configure | Get Cue control-plane ip in SVC network
      set_fact: controller_node_ip="{{ item.1.addr }}"
      with_subelements:
        - servers
        - interfaces
      when: item.1.network == "SVC"
    - name: cue-update-configure | Create ssh-config
      template:
        src: ssh-config.j2
        dest: "{{ playbook_path_output.stdout }}/ssh-config"
EOF

cat > cue-install-packages.yml << 'EOF'
---
- hosts: CUE-API
  sudo: yes
  vars:
    packages: "{{ packages }}"
  tasks:
    - name: cue-install-packages.yml | Update package control plane | Clear deb packages on target host temporary folder
      shell: rm -rf /tmp/packages
    - name: cue-install-packages.yml | Update package control plane | Copy deb packages to target hosts
      copy:
        src: "{{ item }}"
        dest: "/tmp/packages/"
      with_items:
        - "{{ packages }}"
    - name: cue-install-packages.yml | Update package control plane | Find deb packages
      shell: (cd /tmp/packages; find . -maxdepth 1 -type f) | cut -d'/' -f2
      register: debian_files
    - name: cue-install-packages.yml | Update package control plane | Install deb packages
      apt: deb=/tmp/packages/{{ item }}
      with_items:
        - "{{ debian_files.stdout_lines }}"
      register: install_package_result
    - name: cue-install-packages.yml | Update package control plane | Restart hosts
      shell: sleep 2 && shutdown -r now "Packages upgrade triggered"
      async: 1
      poll: 0
      sudo: true
      ignore_errors: true
      when: install_package_result.changed == true

- hosts: localhost
  vars:
    ansible_python_interpreter: /opt/stack/service/ansible/venv/bin/python
    os_auth_url: "{{ lookup('env','OS_AUTH_URL') }}"
    os_region_name: "{{ lookup('env','OS_REGION_NAME') }}"
    os_endpoint_type: "{{ lookup('env','OS_ENDPOINT_TYPE') | default('internalURL', true) }}"
    os_username: "{{ lookup('env','OS_USERNAME') }}"
    os_password: "{{ lookup('env','OS_PASSWORD') }}"
    os_project_name: "{{ lookup('env','OS_PROJECT_NAME') }}"
    os_user_domain_name: "{{ lookup('env','OS_USER_DOMAIN_NAME') | default('Default', true) }}"
    os_project_domain_name: "{{ lookup('env','OS_PROJECT_DOMAIN_NAME') | default('Default', true) }}"
    broker_network_name: "{{ global.pass_through.guest_network_group | default('MSGAAS_NET_BROKER') }}"
  connection: local
  tasks:
    - name: cue-install-packages.yml | Get Broker VM IP's
      shell: >
        /opt/stack/service/ansible/venv/bin/nova list | grep -iE 'cue\[([0-9a-f\-]){36}\]\.node\[[0-9]+\]' | cut -d '|' -f7 | awk -F'{{ broker_network_name }}=' '{gsub(/[ \t]+$/, "", $2); print $2}'
      environment: &OS_ENV
        OS_AUTH_URL: "{{ os_auth_url }}"
        OS_ENDPOINT_TYPE: "{{ os_endpoint_type }}"
        OS_USER_DOMAIN_NAME: "{{ os_user_domain_name }}"
        OS_USERNAME: "{{ os_username }}"
        OS_PASSWORD: "{{ os_password }}"
        OS_PROJECT_DOMAIN_NAME: "{{ os_project_domain_name }}"
        OS_PROJECT_NAME: "{{ os_project_name }}"
        OS_CACERT: /etc/ssl/certs/ca-certificates.crt
        OS_IDENTITY_API_VERSION: 3
        OS_AUTH_VERSION: 3
      register: broker_ips
    - name: cue-install-packages.yml | get_broker_instances | Add broker ip's to in-memory inventory
      add_host:
        groups: brokers
        hostname: "{{ item }}"
      with_items: broker_ips.stdout_lines

- hosts: brokers
  sudo: yes
  vars:
    packages: "{{ packages }}"
  tasks:
    - name: cue-install-packages.yml | Update package brokers | Clear deb packages on target host temporary folder
      shell: rm -rf /tmp/packages
    - name: cue-install-packages.yml | Update package brokers | Copy deb packages to target hosts
      copy:
        src: "{{ item }}"
        dest: "/tmp/packages/"
      with_items:
        - "{{ packages }}"
    - name: cue-install-packages.yml |  Update package brokers | Find deb packages
      shell: (cd /tmp/packages; find . -maxdepth 1 -type f) | cut -d'/' -f2
      register: debian_files
    - name: cue-install-packages.yml |  Update package brokers | Install deb packages
      apt: deb=/tmp/packages/{{ item }}
      with_items:
        - "{{ debian_files.stdout_lines }}"
      register: install_package_result
    - name: cue-install-packages.yml | Update package brokers | Restart hosts
      shell: sleep 2 && shutdown -r now "Packages upgrade triggered"
      async: 1
      poll: 0
      sudo: true
      ignore_errors: true
      when: install_package_result.changed == true
    - name: cue-install-packages.yml | Update package brokers | Waiting for host to come back
      local_action: wait_for host={{ inventory_hostname }} state=started timeout=300
      when: install_package_result.changed == true

- hosts: CUE-API
  tasks:
    - name: cue-install-packages.yml | Update package control plane | Waiting for host to come back
      local_action: wait_for host={{ inventory_hostname }} state=started timeout=300

EOF

cat $1
source ~/user.osrc
ansible-playbook -i hosts/localhost cue-update-configure.yml -vvvv
ansible-playbook -i hosts/verb_hosts cue-install-packages.yml -e "$1" -vvvv

rm ansible.cfg.j2
rm ssh-config.j2
rm ansible.cfg
rm ssh-config
rm cue-update-configure.yml
rm cue-install-packages.yml
