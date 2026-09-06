import contextlib, io, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import paramiko

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'installer'))
import install

class RouterKeyChange(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old=paramiko.RSAKey.generate(1024)
        cls.new=paramiko.RSAKey.generate(1024)

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.keys=Path(self.temp.name)/'known_hosts'
        hosts=paramiko.HostKeys()
        for name in ['192.168.32.1','[192.168.32.1]:2222','192.168.32.2']:
            hosts.add(name,'ssh-rsa',self.old)
        hosts.save(str(self.keys))
        self.before=self.keys.read_bytes()
        self.enterContext(patch.object(install,'KEYS',self.keys))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def changed(self):return paramiko.BadHostKeyException('192.168.32.1',self.new,self.old)

    def test_accept_updates_only_selected_host_and_port(self):
        with patch('paramiko.SSHClient.connect',side_effect=[self.changed(),None]) as connect, patch('builtins.input',return_value='yes'):
            client=install.connect_router('192.168.32.1',2222,'test-password')
            client.close()
        keys=paramiko.HostKeys(str(self.keys))
        self.assertEqual(keys['[192.168.32.1]:2222']['ssh-rsa'],self.new)
        self.assertEqual(keys['192.168.32.1']['ssh-rsa'],self.old)
        self.assertEqual(keys['192.168.32.2']['ssh-rsa'],self.old)
        self.assertEqual(len(self.keys.read_text().splitlines()),3)
        self.assertEqual(connect.call_count,2)

    def test_decline_does_not_retry_or_change_saved_key(self):
        with patch('paramiko.SSHClient.connect',side_effect=self.changed()) as connect, patch('builtins.input',return_value=''):
            with self.assertRaisesRegex(RuntimeError,'not accepted'):
                install.connect_router('192.168.32.1',22,'test-password')
        self.assertEqual(connect.call_count,1)
        self.assertEqual(self.keys.read_bytes(),self.before)

    def test_failed_authentication_does_not_persist_replacement(self):
        with patch('paramiko.SSHClient.connect',side_effect=[self.changed(),paramiko.AuthenticationException('failed')]), patch('builtins.input',return_value='yes'):
            with self.assertRaises(paramiko.AuthenticationException):
                install.connect_router('192.168.32.1',22,'test-password')
        self.assertEqual(self.keys.read_bytes(),self.before)

    def test_second_change_is_rejected(self):
        with patch('paramiko.SSHClient.connect',side_effect=[self.changed(),self.changed()]), patch('builtins.input',return_value='yes') as ask:
            with self.assertRaisesRegex(RuntimeError,'changed again'):
                install.connect_router('192.168.32.1',22,'test-password')
        self.assertEqual(ask.call_count,1)
        self.assertEqual(self.keys.read_bytes(),self.before)

    def test_unchanged_key_needs_no_confirmation(self):
        with patch('paramiko.SSHClient.connect'), patch('builtins.input') as ask:
            client=install.connect_router('192.168.32.1',22,'test-password')
            client.close()
        ask.assert_not_called()
        self.assertEqual(self.keys.read_bytes(),self.before)

if __name__=='__main__':unittest.main()
