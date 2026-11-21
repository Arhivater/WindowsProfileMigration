// Оболочка OpenPGP для одного ZIP. Потоки позволяют переносить архивы больше 4 ГБ.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using Org.BouncyCastle.Bcpg;
using Org.BouncyCastle.Bcpg.OpenPgp;
using Org.BouncyCastle.Security;

namespace WindowsProfileMigration
{
    public static class OpenPgpArchive
    {
        private const int Block = 1 << 16;

        // Пароль остаётся в изменяемом массиве только на время работы с библиотекой.
        private static char[] ReadSecret(SecureString secret)
        {
            if (secret == null || secret.Length == 0)
                throw new ArgumentException("Введите пароль архива.");
            char[] chars = new char[secret.Length];
            IntPtr memory = Marshal.SecureStringToGlobalAllocUnicode(secret);
            try { Marshal.Copy(memory, chars, 0, chars.Length); }
            finally { Marshal.ZeroFreeGlobalAllocUnicode(memory); }
            return chars;
        }

        public static bool SamePassword(SecureString first, SecureString second)
        {
            char[] a = ReadSecret(first);
            try
            {
                char[] b = ReadSecret(second);
                try
                {
                    int difference = a.Length ^ b.Length;
                    for (int i = 0; i < Math.Min(a.Length, b.Length); i++)
                        difference |= a[i] ^ b[i];
                    return difference == 0;
                }
                finally { Array.Clear(b, 0, b.Length); }
            }
            finally { Array.Clear(a, 0, a.Length); }
        }

        // Копируем небольшими блоками. Каждые несколько МБ консоль может принять отмену.
        private static void Copy(Stream input, Stream output, long limit, Func<bool> cancel)
        {
            byte[] buffer = new byte[Block];
            long total = 0, nextCheck = 0;
            try
            {
                int n;
                while ((n = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    total = checked(total + n);
                    if (total > limit) throw new InvalidDataException("Превышен размер исходного файла.");
                    if (total >= nextCheck)
                    {
                        if (cancel != null && cancel()) throw new OperationCanceledException();
                        nextCheck = total + 4L * 1024 * 1024;
                    }
                    output.Write(buffer, 0, n);
                }
            }
            finally { Array.Clear(buffer, 0, buffer.Length); }
        }

        public static void Encrypt(Stream zip, Stream output, SecureString password, Func<bool> cancel)
        {
            var envelope = new PgpEncryptedDataGenerator(SymmetricKeyAlgorithmTag.Aes256, true, new SecureRandom());
            char[] chars = ReadSecret(password);
            // 0xff задаёт максимальную стандартную стоимость salted-and-iterated S2K (RFC 4880).
            try { envelope.AddMethodUtf8(chars, HashAlgorithmTag.Sha256, 0xff); }
            finally { Array.Clear(chars, 0, chars.Length); }

            var data = new PgpLiteralDataGenerator();
            using (Stream encrypted = envelope.Open(output, new byte[Block]))
            using (Stream literal = data.Open(encrypted, PgpLiteralData.Binary, "profile.zip", DateTime.UtcNow, new byte[Block]))
                Copy(zip, literal, zip.Length, cancel);
        }

        // Наш формат содержит одну запись симметричного ключа и один защищённый пакет.
        // Проверяем короткий заголовок до разбора содержимого из неизвестного файла.
        private static void CheckHeader(Stream source)
        {
            int tag = source.ReadByte();
            if ((tag != 0x8c && tag != 0xc3) || source.ReadByte() != 13 ||
                source.ReadByte() != 4 || source.ReadByte() != (int)SymmetricKeyAlgorithmTag.Aes256 ||
                source.ReadByte() != 3 || source.ReadByte() != (int)HashAlgorithmTag.Sha256)
                throw new InvalidDataException();
            source.Position = 15;
            if (source.ReadByte() != 0xd2) throw new InvalidDataException();
            source.Position = 0;
        }

        public static void Decrypt(Stream source, Stream zip, SecureString password, Func<bool> cancel)
        {
            CheckHeader(source);
            var outer = new BcpgInputStream(source);
            var entries = new PgpObjectFactory(outer).NextPgpObject() as PgpEncryptedDataList;
            var packet = entries != null && entries.Count == 1 ? entries[0] as PgpPbeEncryptedData : null;
            if (packet == null || !packet.IsIntegrityProtected()) throw new InvalidDataException();

            char[] chars = ReadSecret(password);
            Stream clear;
            try { clear = packet.GetDataStreamUtf8(chars); }
            finally { Array.Clear(chars, 0, chars.Length); }
            using (clear)
            {
                var body = new BcpgInputStream(clear);
                if (body.NextPacketTag() != PacketTag.LiteralData) throw new InvalidDataException();
                var data = new PgpLiteralData(body);
                if (data.Format != PgpLiteralData.Binary || data.FileName != "profile.zip")
                    throw new InvalidDataException();
                Copy(data.GetInputStream(), zip, source.Length, cancel);
                if ((int)body.NextPacketTag() != -1 || !packet.Verify() || (int)outer.NextPacketTag() != -1)
                    throw new InvalidDataException();
            }
        }
    }
}
